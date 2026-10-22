import AppKit
import AVFoundation
import CryptoKit
import MediaAccessibility
import UniformTypeIdentifiers

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [PlayerWindowController] = []
    private var openedAny = false

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for a in args { open(URL(fileURLWithPath: a)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if !openedAny { openDocument(nil) }
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) { urls.forEach(open) }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func open(_ url: URL) {
        openedAny = true
        NSDocumentController.shared.noteNewRecentDocumentURL(url)   // File › Open Recent and the Dock menu
        if let existing = windows.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = PlayerWindowController(url: url)
        windows.append(wc)
        wc.onClose = { [weak self, weak wc] in self?.windows.removeAll { $0 === wc } }
        wc.showWindow(nil)
    }

    @objc func showSettings() {
        SettingsWindowController.shared.reload()
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
        SettingsWindowController.shared.window?.makeFirstResponder(nil)   // don't open with a value field selected
    }

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .video, .audiovisualContent]
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    private func buildMenu() { NSApp.mainMenu = MainMenu.build(self) }
}

// MARK: - Window

final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    let view: PlayerView
    let url: URL

    init(url: URL) {
        self.url = url
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(1280, screen.width * 0.7)
        let rect = NSRect(x: screen.midX - w / 2, y: screen.midY - w * 9 / 32, width: w, height: w * 9 / 16)
        let win = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = .black
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.fullScreenPrimary]
        win.title = url.lastPathComponent
        view = PlayerView(frame: rect)
        win.contentView = view
        super.init(window: win)
        win.delegate = self
        view.load(url)
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ n: Notification) { view.teardown(); onClose?() }
}

// MARK: - Player view

final class PlayerView: NSView {
    private(set) var backend: Playback?
    private let videoHost = CALayer()          // the backend's own layer goes in here
    private let scrubLayer = AVSampleBufferDisplayLayer()
    private let controls = ControlBar()
    private let hud = NSTextField(labelWithString: "")
    private let volumeBadge = VolumeBadge()
    private let previewBubble = PreviewBubble()
    private var thumbnailer: Thumbnailer?
    private let captionOverlay = CaptionOverlay()
    private var mkv: MKVFile?
    private(set) var captionSources: [CaptionSource] = []
    private(set) var captionChoice: Int?                 // index into captionSources; nil = off
    private var lastCaptionChoice = 0
    private let status = NSTextField(labelWithString: "")

    private var engine: ScrubEngine?
    private var index: MediaIndex?
    private var duration: Double = 0
    private var clock: Timer?

    // seeking state
    private var target: Int?                  // engine frame we're heading to (nil = follow the player)
    private var resumeAfterSeek = false
    private var settleWork: DispatchWorkItem?
    private var settleGen = 0
    private var dragging = false
    private var hideWork: DispatchWorkItem?
    private var fmtCache: CMVideoFormatDescription?
    private var exactShown = -1
    private var pendingSettle = false
    private var trimWork: DispatchWorkItem?
    private var pendingTrim: Int?
    private var legibleGroup: AVMediaSelectionGroup?

    static let rates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3, 3.5, 4, 5, 6, 8]
    private var rate: Float = {
        let r = UserDefaults.standard.float(forKey: "rate")
        return r > 0 ? r : 1
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        scrubLayer.videoGravity = .resizeAspect
        scrubLayer.isHidden = true
        for l in [videoHost, scrubLayer] as [CALayer] { layer?.addSublayer(l) }

        captionOverlay.autoresizingMask = [.width, .height]
        addSubview(captionOverlay)
        controls.autoresizingMask = [.width]
        addSubview(controls)
        controls.scrubber.onBegin = { [weak self] in self?.beginDrag() }
        controls.scrubber.onMove = { [weak self] f in self?.seek(fraction: f) }
        controls.scrubber.onEnd = { [weak self] in self?.endDrag() }
        controls.scrubber.onStep = { [weak self] by in self?.skip(by) }
        controls.scrubber.onHover = { [weak self] f in self?.preview(at: f) }
        controls.onPlay = { [weak self] in self?.togglePlay() }
        controls.onRate = { [weak self] in self?.faster() }
        controls.onMute = { [weak self] in self?.toggleMute(nil) }
        controls.onVolume = { [weak self] v in self?.setVolume(v) }

        for t in [hud, status] {
            t.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            t.textColor = .white
            t.alignment = .center
            t.wantsLayer = true
            t.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
            t.layer?.cornerRadius = 8
            t.alphaValue = 0
            addSubview(t)
        }
        addSubview(volumeBadge)
        addSubview(previewBubble)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoHost.frame = bounds
        backend?.layer.frame = videoHost.bounds
        scrubLayer.frame = bounds
        CATransaction.commit()
        controls.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 64)
        hud.sizeToFit()
        hud.frame = NSRect(x: bounds.midX - 50, y: bounds.maxY - 80, width: 100, height: 30)
        status.frame = NSRect(x: bounds.midX - 160, y: bounds.midY - 15, width: 320, height: 30)
        captionOverlay.frame = bounds
    }

    // MARK: loading

    func load(_ url: URL) {
        Task { @MainActor in
            let opened = CACurrentMediaTime()
            var size = CGSize.zero
            let asset = AVURLAsset(url: url)
            var newIndex: MediaIndex?
            var playAsset: AVURLAsset?
            if (try? await asset.load(.isPlayable)) == true {
                playAsset = asset
                if let (native, idx) = await NativePlayback.make(asset: asset) {
                    // decodes only a few frames ahead: about 100 MB less than AVPlayer for 4K
                    native.onEnd = { [weak self] in self?.controls.setTime(self?.duration ?? 0, playing: false) }
                    backend = native
                    newIndex = idx
                    duration = idx.duration
                } else {
                    backend = AVPlayerPlayback(asset: asset)
                    duration = (try? await asset.load(.duration).seconds) ?? 0
                }
                size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            } else if let (mkv, idx) = await Task.detached(operation: { () -> (MKVFile, MediaIndex)? in
                          // Matroska natively: parse, index, and play without touching ffmpeg
                          guard let m = MKVFile(url: url), !NativePlayback.hasUndecodableAudioOnly(m),
                                let i = MediaIndex(mkv: m), ScrubEngine.canDecode(i) else { return nil }
                          return (m, i)
                      }).value {
                let native = NativePlayback(mkv: mkv, index: idx)
                native.onEnd = { [weak self] in self?.controls.setTime(self?.duration ?? 0, playing: false) }
                backend = native
                newIndex = idx
                self.mkv = mkv
                duration = idx.duration
                let v = mkv.video!
                size = CGSize(width: v.displayWidth > 0 ? v.displayWidth : v.width, height: v.displayHeight > 0 ? v.displayHeight : v.height)
            } else {
                // DTS/TrueHD-only audio, VP9…: stream-copy into MP4 and transcode the audio
                flash(status, "Preparing \(url.pathExtension.uppercased())…", hold: true)
                guard let remuxed = await Remuxer.remux(url) else { flash(status, "Can't open this file"); return }
                status.alphaValue = 0
                let a = AVURLAsset(url: remuxed)
                playAsset = a
                backend = AVPlayerPlayback(asset: a)
                duration = (try? await a.load(.duration).seconds) ?? 0
                size = (try? await a.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            }
            guard let backend else { return }
            Trace.log(String(format: "open %.1f ms", (CACurrentMediaTime() - opened) * 1000))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            backend.layer.frame = videoHost.bounds
            videoHost.addSublayer(backend.layer)
            CATransaction.commit()
            if size.width > 0 {
                window?.contentAspectRatio = size
                if let w = window, !w.styleMask.contains(.fullScreen) {
                    var f = w.frame
                    f.size.height = f.width * size.height / size.width
                    w.setFrame(f, display: true)
                }
            }
            controls.duration = duration
            controls.setVolume(backend.volume, muted: backend.isMuted)
            if size.width > 0, size.height > 0 { previewBubble.aspect = size.width / size.height }
            tick()
            controls.setRate(rate)
            backend.setRate(rate)
            backend.play(rate: rate)
            showControls()
            // Build the frame index off the main thread; until it lands, seeks go straight to the backend.
            await loadCaptions(from: url, asset: playAsset)
            if newIndex == nil, let playAsset { newIndex = await MediaIndex(asset: playAsset) }
            if ProcessInfo.processInfo.environment["FLICK_NO_ENGINE"] != nil { return }   // diagnostics only
            if let idx = newIndex, let eng = ScrubEngine(index: idx) {
                eng.onFrame = { [weak self] px, d, exact in
                    self?.display(px)
                    if exact { DispatchQueue.main.async { self?.engineReached(d) } }
                }
                eng.onFail = { [weak self] d in DispatchQueue.main.async { self?.engineFailed(d) } }
                eng.setIdle(!backend.isPlaying)
                index = idx
                engine = eng
                thumbnailer = Thumbnailer(index: idx)
            }
        }
    }

    /// UI clock. 30 Hz only while something on screen moves with it (visible controls, captions);
    /// otherwise 4 Hz, with timer tolerance so macOS can coalesce wakeups. Saves energy during playback.
    private func tick() {
        if target == nil, let b = backend {
            let t = b.currentSeconds
            if controls.alphaValue > 0 { controls.setTime(t, playing: b.isPlaying) } else { controls.noteTime(t) }
            captionOverlay.update(time: t)
        }
        let fast = controls.alphaValue > 0 || !captionOverlay.isHidden
        let interval = fast ? 1.0 / 30 : 0.25
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.tick() }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    func teardown() {
        engine?.stop()
        clock?.invalidate()
        backend?.teardown()
    }

    /// Runs on VideoToolbox's output thread: put the picture straight on the display layer.
    private func display(_ px: CVPixelBuffer) {
        if fmtCache == nil || !CMVideoFormatDescriptionMatchesImageBuffer(fmtCache!, imageBuffer: px) {
            var f: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: px, formatDescriptionOut: &f)
            fmtCache = f
        }
        guard let fmt = fmtCache else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: px, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary], let d = a.first {
            d[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        scrubLayer.sampleBufferRenderer.enqueue(sb)
    }

    // MARK: seeking

    private var currentFrame: Int? {
        guard let index else { return nil }
        return target ?? index.frame(at: backend?.currentSeconds ?? 0)
    }

    private func seek(toFrame d: Int, settleAfter delay: Double?) {
        guard let engine, let index else { return }
        settleGen &+= 1
        settleWork?.cancel()
        trimWork?.cancel(); pendingTrim = nil
        if target == nil {
            resumeAfterSeek = backend?.isPlaying ?? false
            backend?.pause()
            engine.setIdle(true)
        }
        // the backend shares the hardware decoder: never let a stale hand-back seek compete with the scrub engine
        backend?.cancelSeeks()
        pendingSettle = false
        target = d
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scrubLayer.isHidden = false
        CATransaction.commit()
        engine.seek(frame: d)
        controls.setTime(index.seconds(d), playing: resumeAfterSeek)
        captionOverlay.update(time: index.seconds(d))
        if let delay {
            let w = DispatchWorkItem { [weak self] in self?.settle() }
            settleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        }
    }

    private func engineReached(_ d: Int) {
        Trace.log("app reached \(d) target \(target ?? -1) trim \(pendingTrim ?? -1) settle \(pendingSettle)")
        exactShown = d
        if pendingTrim == d {
            pendingTrim = nil
            backend?.suspend()
            engine?.prefetch([])
        }
        guard pendingSettle, d == target else { return }
        pendingSettle = false
        settle()
    }

    /// The engine couldn't decode the frame it was asked for. Never leave the player waiting on it:
    /// an idle trim is abandoned (the backend still has its picture); a hand-off goes ahead and lets
    /// the backend seek to the exact frame itself.
    private func engineFailed(_ d: Int) {
        Trace.log("app engine failed \(d) target \(target ?? -1)")
        guard d == target else { return }
        if pendingTrim == d {
            pendingTrim = nil
            target = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            scrubLayer.isHidden = true
            CATransaction.commit()
        } else if pendingSettle {
            pendingSettle = false
            exactShown = d
            syncPlayer(d, gen: settleGen)
        }
    }

    /// The user stopped seeking: once the engine has the exact frame on screen, bring AVPlayer to the same
    /// frame and hand the screen back to it. Waiting keeps the two from fighting over the one hardware decoder.
    private func settle() {
        guard let d = target, let index else { return }
        if exactShown != d { pendingSettle = true; return }
        let g = settleGen
        if !resumeAfterSeek {
            // paused: give the user a beat to seek again before spending decoder time on AVPlayer
            let w = DispatchWorkItem { [weak self] in
                guard let self, g == self.settleGen else { return }
                self.syncPlayer(d, gen: g)
            }
            settleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        } else {
            syncPlayer(d, gen: g)
        }
    }

    private func syncPlayer(_ d: Int, gen g: Int, attempt: Int = 0) {
        guard let index else { return }
        Trace.log("app sync \(d) attempt \(attempt)")
        backend?.seek(to: index.seconds(d) + index.frameDuration * 0.5) { [weak self] ok in
            Trace.log("app sync done \(d) ok \(ok)")
            do {
                guard let self, g == self.settleGen else { return }
                // an interrupted seek with nothing newer behind it: try again rather than leave the
                // scrub picture up and the player stopped
                guard ok else {
                    if attempt < 3 { self.syncPlayer(d, gen: g, attempt: attempt + 1) }
                    return
                }
                self.target = nil
                if self.resumeAfterSeek {
                    self.engine?.prefetch([])
                    self.engine?.setIdle(false)
                    self.backend?.play(rate: self.rate)
                } else if let e = self.engine {
                    let s = index.seconds(d)
                    e.prefetch([s + 5, s - 5, s + 1, s - 1].filter { $0 >= 0 && $0 < index.duration }.map(index.frame(at:)))
                    self.scheduleTrim()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard g == self.settleGen else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.scrubLayer.isHidden = true
                    self.scrubLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)   // free the last 4K picture
                    CATransaction.commit()
                }
            }
        }
    }

    private func seek(seconds s: Double, settleAfter delay: Double?) {
        let s = max(0, min(duration - 0.001, s))
        if let index {
            seek(toFrame: index.frame(at: s), settleAfter: delay)
        } else {
            backend?.seek(to: s) { _ in }
            controls.setTime(s, playing: backend?.isPlaying ?? false)
        }
    }

    private func skip(_ by: Double) {
        let base = currentFrame.flatMap { index?.seconds($0) } ?? backend?.currentSeconds ?? 0
        seek(seconds: base + by, settleAfter: 0.25)
    }

    private func stepFrame(_ n: Int) {
        guard let d = currentFrame, let index else { return }
        seek(toFrame: index.step(d, by: n), settleAfter: 0.4)
    }

    private func beginDrag() {
        dragging = true
        showControls()
    }

    private func seek(fraction f: Double) {
        seek(seconds: f * duration, settleAfter: nil)
    }

    private func endDrag() {
        dragging = false
        engine?.settle()
        settle()
        scheduleHide()
    }

    // MARK: playback

    @objc func togglePlay() {
        Trace.log("app toggle target \(target ?? -1) playing \(backend?.isPlaying ?? false) exact \(exactShown)")
        trimWork?.cancel(); pendingTrim = nil
        if target != nil {
            resumeAfterSeek.toggle()
            settleWork?.cancel()
            settle()
        } else if backend?.isPlaying == true {
            backend?.pause()
            engine?.setIdle(true)
            scheduleTrim()
            if let index, let e = engine {
                let s = backend?.currentSeconds ?? 0
                e.prefetch([s + 5, s - 5, s + 1, s - 1].filter { $0 >= 0 && $0 < index.duration }.map(index.frame(at:)))
            }
        } else {
            engine?.prefetch([])
            engine?.setIdle(false)
            backend?.play(rate: rate)
        }
        controls.setTime(controls.time, playing: target != nil ? resumeAfterSeek : backend?.isPlaying ?? false)
    }

    private func setRate(_ r: Float) {
        rate = r
        UserDefaults.standard.set(r, forKey: "rate")
        backend?.setRate(r)
        controls.setRate(r)
        flash(hud, PlayerView.label(r))
    }

    static func label(_ r: Float) -> String {
        r == r.rounded() ? String(format: "%.0f×", r) : String(format: "%g×", r)
    }

    private func changeVolume(_ by: Float) {
        guard let b = backend else { return }
        b.volume = max(0, min(1, b.volume + by))
        if by != 0, b.isMuted { b.isMuted = false }
        volumeBadge.show(b.volume, muted: b.isMuted, in: bounds)
        controls.setVolume(b.volume, muted: b.isMuted)
    }

    /// From the control-bar slider: the slider itself shows the level, so no badge.
    private func setVolume(_ v: Float) {
        guard let b = backend else { return }
        b.volume = max(0, min(1, v))
        if b.isMuted && v > 0 { b.isMuted = false }
        controls.setVolume(b.volume, muted: b.isMuted)
        scheduleHide()
    }

    // MARK: timeline preview

    /// Hovering or dragging on the seek bar: the time there and the keyframe at or before it.
    private func preview(at f: Double?) {
        guard let f, duration > 0, controls.alphaValue > 0 || dragging else { previewBubble.show(false); return }
        let t = f * duration
        previewBubble.setTime(ControlBar.fmt(t))
        let bar = convert(controls.scrubber.bounds, from: controls.scrubber)
        let w = PreviewBubble.width, h = previewBubble.height
        let cx = bar.minX + controls.scrubber.x(at: f)
        previewBubble.frame = NSRect(x: max(8, min(bounds.width - w - 8, cx - w / 2)), y: bar.maxY + 6, width: w, height: h)
        previewBubble.show(true)
        guard let th = thumbnailer, let index else { return }
        th.spacing = dragging ? 0.08 : 0          // leave the hardware decoder to the main picture while dragging
        th.request(frame: index.frame(at: t)) { [weak self] img, k in
            guard let self, self.previewBubble.alphaValue > 0 else { return }
            self.previewBubble.setPicture(img, key: k)
        }
    }

    @objc func faster() { setRate(Self.rates.first { $0 > rate + 0.001 } ?? Self.rates.last!) }
    @objc func slower() { setRate(Self.rates.last { $0 < rate - 0.001 } ?? Self.rates.first!) }
    @objc func normalSpeed() { setRate(1) }

    // MARK: captions

    /// Embedded tracks (AVPlayer renders them, in the user's system caption style), Matroska text tracks,
    /// and subtitle files sitting next to the video. Turned on automatically when the user's Accessibility
    /// setting prefers captions.
    private func loadCaptions(from url: URL, asset: AVURLAsset?) async {
        var sources: [CaptionSource] = []
        legibleGroup = try? await asset?.loadMediaSelectionGroup(for: .legible)
        (backend as? AVPlayerPlayback)?.legibleGroup = legibleGroup
        if let group = legibleGroup {
            sources += group.options.map { .embedded($0) }
        }
        if let mkv {
            sources += mkv.tracks.filter { $0.type == 17 }.map { CaptionParser.mkvTrack(mkv, $0) }
        }
        let sidecars = await Task.detached { CaptionParser.sidecars(for: url).compactMap(CaptionParser.load) }.value
        sources += sidecars
        captionSources = sources
        if let item = (backend as? AVPlayerPlayback)?.player.currentItem, let group = legibleGroup,
           let current = item.currentMediaSelection.selectedMediaOption(in: group),
           let i = sources.firstIndex(where: { if case .embedded(let o) = $0 { return o == current }; return false }) {
            captionChoice = i                      // AVPlayer already applied the system caption preference
        } else if MACaptionAppearanceGetDisplayType(.user) == .alwaysOn, let first = preferredCaption() {
            selectCaption(first)
        }
    }

    private func preferredCaption() -> Int? {
        let langs = (MACaptionAppearanceCopySelectedLanguages(.user).takeRetainedValue() as? [String] ?? []) + Locale.preferredLanguages
        let usable = captionSources.indices.filter { if case .unsupported = captionSources[$0] { return false }; return true }
        for l in langs {
            let code = String(l.prefix(2))
            if let i = usable.first(where: { captionSources[$0].title.lowercased().contains(Locale.current.localizedString(forLanguageCode: code)?.lowercased() ?? "~") }) { return i }
        }
        return usable.first
    }

    private func selectCaption(_ i: Int?) {
        let item = (backend as? AVPlayerPlayback)?.player.currentItem
        let group = legibleGroup
        captionChoice = i
        captionOverlay.set([])
        if let group { item?.select(nil, in: group) }
        guard let i, captionSources.indices.contains(i) else { return }
        lastCaptionChoice = i
        switch captionSources[i] {
        case .embedded(let o): if let group { item?.select(o, in: group) }
        case .cues(_, let cues):
            captionOverlay.set(cues)
            captionOverlay.update(time: currentFrame.flatMap { index?.seconds($0) } ?? backend?.currentSeconds ?? 0)
        case .unsupported: captionChoice = nil
        }
    }

    func fillSubtitlesMenu(_ menu: NSMenu) {
        let off = menu.addItem(withTitle: "Off", action: #selector(chooseCaption(_:)), keyEquivalent: "")
        off.tag = -1
        off.state = captionChoice == nil ? .on : .off
        if !captionSources.isEmpty { menu.addItem(.separator()) }
        for (i, src) in captionSources.enumerated() {
            let it = menu.addItem(withTitle: src.title, action: #selector(chooseCaption(_:)), keyEquivalent: "")
            it.tag = i
            it.state = captionChoice == i ? .on : .off
            if case .unsupported = src { it.isEnabled = false; it.action = nil }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Subtitle File…", action: #selector(addSubtitleFile(_:)), keyEquivalent: "")
    }

    @objc func chooseCaption(_ s: NSMenuItem) { selectCaption(s.tag < 0 ? nil : s.tag) }

    @objc func toggleSubtitles(_ s: Any?) {
        if captionChoice != nil { selectCaption(nil); flash(hud, "Subtitles Off") }
        else if let i = captionSources.indices.contains(lastCaptionChoice) ? lastCaptionChoice : preferredCaption() {
            selectCaption(i); flash(hud, captionChoice == nil ? "No Subtitles" : "Subtitles On")
        } else { flash(hud, "No Subtitles") }
    }

    @objc func addSubtitleFile(_ s: Any?) {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = CaptionParser.sidecarExtensions.compactMap { UTType(filenameExtension: $0) }
        p.allowsOtherFileTypes = true
        p.message = "Choose a subtitle file (SRT, WebVTT or ASS)"
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self, r == .OK, let u = p.url else { return }
            guard let src = CaptionParser.load(u) else { self.flash(self.hud, "Can't read that subtitle file"); return }
            self.captionSources.append(src)
            self.selectCaption(self.captionSources.count - 1)
        }
    }

    // MARK: idle memory trim

    /// Paused and untouched for 3 s: put the exact current frame on the scrub layer, then let the playback
    /// backend drop its video decoder. Play or seek rebuilds it through the normal hand-off.
    private func scheduleTrim() {
        trimWork?.cancel()
        guard engine != nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.trimIdle() }
        trimWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func trimIdle() {
        guard let backend, let index, let engine, !backend.isPlaying, !backend.isSuspended, !dragging else { return }
        let d = target ?? index.frame(at: backend.currentSeconds)
        Trace.log("app trim \(d)")
        settleGen &+= 1
        resumeAfterSeek = false
        target = d
        pendingTrim = d
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scrubLayer.isHidden = false
        CATransaction.commit()
        engine.setIdle(true)
        engine.seek(frame: d)
        engine.redisplay()
    }

    // MARK: menu commands (every player command is in the menu bar; keys arrive through it)

    @objc func menuSkip(_ s: NSMenuItem) { skip(s.representedObject as? Double ?? 0) }
    @objc func nextFrame(_ s: Any?) { stepFrame(1) }
    @objc func previousFrame(_ s: Any?) { stepFrame(-1) }
    @objc func volumeUp(_ s: Any?) { changeVolume(0.05) }
    @objc func volumeDown(_ s: Any?) { changeVolume(-0.05) }
    @objc func toggleMute(_ s: Any?) {
        guard let b = backend else { return }
        b.isMuted.toggle()
        volumeBadge.show(b.volume, muted: b.isMuted, in: bounds)
        controls.setVolume(b.volume, muted: b.isMuted)
    }
    @objc func setSpeedFromMenu(_ s: NSMenuItem) { setRate(Float(s.tag)) }
    @objc func performShortcutItem(_ s: NSMenuItem) {
        guard let i = s.representedObject as? Int, Shortcuts.shared.items.indices.contains(i) else { return }
        perform(Shortcuts.shared.items[i])
    }
    @objc func toggleControllerVisibility(_ s: Any?) {
        perform(Shortcut(action: .toggleController, key: "", modifiers: 0, value: 0))
    }

    /// Titles follow state; items without ⌘ only fire for the key player window (so typing elsewhere is safe).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if !item.keyEquivalent.isEmpty, !item.keyEquivalentModifierMask.contains(.command), window != NSApp.keyWindow { return false }
        switch item.action {
        case #selector(togglePlay):
            let playing = target != nil ? resumeAfterSeek : backend?.isPlaying ?? false
            item.title = playing ? "Pause" : "Play"
        case #selector(toggleMute(_:)): item.title = backend?.isMuted == true ? "Unmute" : "Mute"
        case #selector(toggleControllerVisibility(_:)): item.title = controlsHiddenByUser ? "Show Controls" : "Hide Controls"
        case #selector(nextFrame(_:)), #selector(previousFrame(_:)): return index != nil
        case #selector(setSpeedFromMenu(_:)): item.state = abs(rate - Float(item.tag)) < 0.001 ? .on : .off
        case #selector(normalSpeed): item.state = rate == 1 ? .on : .off
        default: break
        }
        return backend != nil
    }

    // MARK: input

    // MARK: configurable shortcuts (Settings)

    private var controlsHiddenByUser = false
    private var rateBeforeReset: Float?

    private func perform(_ sc: Shortcut) {
        let v = Float(sc.value)
        func round2(_ r: Float) -> Float { (r * 100).rounded() / 100 }
        switch sc.action {
        case .toggleController:
            controlsHiddenByUser.toggle()
            if controlsHiddenByUser {
                hideWork?.cancel()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.15; controls.animator().alphaValue = 0 }
            } else { showControls() }
        case .slower: setRate(max(0.07, round2(rate - v)))
        case .faster: setRate(min(16, round2(rate + v)))
        case .rewind: skip(-sc.value)
        case .advance: skip(sc.value)
        case .resetSpeed:
            // like Video Speed Controller: 1× and back to where you were
            if rate != 1 { rateBeforeReset = rate; setRate(1) } else if let r = rateBeforeReset { setRate(r) }
        case .preferredSpeed:
            if rate != v { rateBeforeReset = rate; setRate(v) } else { setRate(rateBeforeReset ?? 1) }
        case .playPause: togglePlay()
        case .mute: toggleMute(nil)
        case .toggleSubtitles: toggleSubtitles(nil)
        }
    }

    override func keyDown(with e: NSEvent) {
        if let sc = Shortcuts.shared.match(e) { perform(sc); return }
        let shift = e.modifierFlags.contains(.shift)
        let alt = e.modifierFlags.contains(.option)
        switch e.keyCode {
        case 123: skip(shift ? -1 : alt ? -30 : -5)
        case 124: skip(shift ? 1 : alt ? 30 : 5)
        case 126: changeVolume(0.05)
        case 125: changeVolume(-0.05)
        case 49: togglePlay()
        case 116 where shift: skip(600)
        case 121 where shift: skip(-600)
        case 53: if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        default:
            switch e.charactersIgnoringModifiers {
            case ",": stepFrame(-1)
            case ".": stepFrame(1)
            case "f": window?.toggleFullScreen(nil)
            case "m": if let b = backend { b.isMuted.toggle(); flash(hud, b.isMuted ? "Muted" : "Sound"); controls.setVolume(b.volume, muted: b.isMuted) }
            case "]": faster()
            case "[": slower()
            case "\\", "\u{7f}": normalSpeed()
            case let c? where Int(c).map({ (1...4).contains($0) }) == true: setRate(Float(Int(c)!))
            default: super.keyDown(with: e)
            }
        }
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { window?.toggleFullScreen(nil) } else { super.mouseDown(with: e) }
    }

    override func scrollWheel(with e: NSEvent) {
        if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) {
            skip(-Double(e.scrollingDeltaX) * (e.hasPreciseScrollingDeltas ? 0.05 : 1))
            return
        }
        // Two fingers up = louder, whatever the natural-scrolling setting; ignore the momentum tail.
        guard e.momentumPhase.isEmpty, e.scrollingDeltaY != 0 else { return }
        let up = Float(e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY)
        changeVolume(e.hasPreciseScrollingDeltas ? up * 0.003 : (up > 0 ? 0.05 : -0.05))
    }

    override func mouseMoved(with e: NSEvent) { showControls() }
    override func mouseExited(with e: NSEvent) { scheduleHide(after: 0.15) }

    /// Pointer over the traffic-light corner: keep everything up while the user reaches for a button.
    private var overWindowButtons: Bool {
        guard let w = window else { return false }
        let p = w.mouseLocationOutsideOfEventStream
        return p.x >= 0 && p.x < 90 && p.y <= w.frame.height && p.y > w.frame.height - 36
    }

    /// The close/minimise/zoom buttons appear only while the pointer is over the player, with the controls.
    private func setWindowButtons(visible: Bool, duration: Double) {
        guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            for b in buttons { b.animator().alphaValue = visible ? 1 : 0 }
        }
    }

    private func showControls() {
        NSCursor.setHiddenUntilMouseMoves(false)
        if controls.alphaValue == 0, target == nil, let b = backend { controls.setTime(b.currentSeconds, playing: b.isPlaying) }
        if controlsHiddenByUser { setWindowButtons(visible: true, duration: 0.12); scheduleHide(); return }
        if controls.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; controls.animator().alphaValue = 1 }
        }
        setWindowButtons(visible: true, duration: 0.12)
        scheduleHide()
    }

    private func scheduleHide(after s: Double = 0.8) {
        if NSWorkspace.shared.isVoiceOverEnabled { hideWork?.cancel(); return }   // HIG: avoid time-boxed UI for assistive tech
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.dragging, !self.controls.isMouseInside, !self.overWindowButtons else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self.controls.animator().alphaValue = 0 }
            self.previewBubble.show(false)
            self.setWindowButtons(visible: false, duration: 0.25)
            if self.window?.isKeyWindow == true { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    private func flash(_ f: NSTextField, _ text: String, hold: Bool = false) {
        f.stringValue = text
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let w = max(90, f.attributedStringValue.size().width + 28)
        f.frame.size.width = w
        f.frame.origin.x = bounds.midX - w / 2
        f.alphaValue = 1
        if hold { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            f.animator().alphaValue = 0
        })
    }
}

// MARK: - Controls

final class ControlBar: NSView {
    let scrubber = Scrubber()
    private let play = NSButton()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let durLabel = NSTextField(labelWithString: "0:00")
    private let rateButton = NSButton()
    private let muteButton = NSButton()
    private let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let gradient = CAGradientLayer()
    var onPlay: (() -> Void)?
    var onRate: (() -> Void)?
    var onMute: (() -> Void)?
    var onVolume: ((Float) -> Void)?
    var duration: Double = 0 { didSet { durLabel.stringValue = Self.fmt(duration); needsLayout = true } }
    private(set) var time: Double = 0
    var isMouseInside: Bool {
        guard let w = window else { return false }
        return bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Increase Contrast: a near-opaque backing instead of the soft fade
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        gradient.colors = [NSColor(white: 0, alpha: contrast ? 0.92 : 0.7).cgColor, NSColor(white: 0, alpha: contrast ? 0.6 : 0).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(gradient)
        play.isBordered = false
        play.contentTintColor = .white
        play.target = self; play.action = #selector(tapPlay)
        rateButton.isBordered = false
        rateButton.setAccessibilityLabel("Playback speed")
        rateButton.toolTip = "Playback speed (click for faster)"
        play.toolTip = "Play/Pause (Space)"
        rateButton.target = self; rateButton.action = #selector(tapRate)
        for l in [timeLabel, durLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            l.textColor = NSColor(white: 1, alpha: 0.9)
        }
        durLabel.alignment = .right
        muteButton.isBordered = false
        muteButton.contentTintColor = .white
        muteButton.target = self; muteButton.action = #selector(tapMute)
        muteButton.toolTip = "Mute (M)"
        volume.controlSize = .small
        volume.isContinuous = true
        volume.appearance = NSAppearance(named: .darkAqua)
        volume.trackFillColor = .white
        volume.target = self; volume.action = #selector(slideVolume)
        volume.setAccessibilityLabel("Volume")
        volume.toolTip = "Volume (↑ ↓ or two-finger swipe)"
        [play, muteButton, volume, timeLabel, scrubber, durLabel, rateButton].forEach(addSubview)
        setTime(0, playing: true)
        setVolume(1, muted: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        // Every element sized to what it draws, 20 pt from the edges and 20 pt apart (HIG: consistent spacing).
        let edge: CGFloat = 20, gap: CGFloat = 20, mid: CGFloat = 28
        func place(_ v: NSView, _ x: CGFloat, _ w: CGFloat, _ h: CGFloat) { v.frame = NSRect(x: x, y: (mid - h / 2).rounded(), width: w, height: h) }
        let playW = Self.playWidth
        let muteW = Self.speakerWidth
        let labelW = ceil(NSAttributedString(string: Self.fmt(max(duration, 600)).replacingOccurrences(of: #"\d"#, with: "0", options: .regularExpression),
                                             attributes: [.font: timeLabel.font!]).size().width) + 4   // + the label's own 2 pt insets
        let rateW = ceil(rateButton.attributedTitle.size().width)
        var x = edge
        place(play, x, playW, 28); x += playW + gap
        place(timeLabel, x - 2, labelW, 16); x += labelW - 4 + gap
        var r = bounds.width - edge
        place(volume, r - 74, 76, 20); r -= 72 + gap          // the slider draws its knob 2 pt inside its frame
        place(muteButton, r - muteW, muteW, 24); r -= muteW + gap
        place(rateButton, r - rateW, rateW, 24); r -= rateW + gap
        place(durLabel, r - labelW + 2, labelW, 16); r -= labelW - 4 + gap
        // the bar's track is inset 6 pt inside its frame
        place(scrubber, x - 6, max(40, r - x + 12), 28)
    }

    static let playWidth: CGFloat = ["play.fill", "pause.fill"]
        .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))?.size.width }
        .max() ?? 16

    /// Widest of the speaker glyphs, so the slider doesn't shift when the icon changes.
    static let speakerWidth: CGFloat = ["speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]
        .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))?.size.width }
        .max() ?? 20

    /// Hidden controls: remember the time without touching any view.
    func noteTime(_ t: Double) { time = t }

    func setTime(_ t: Double, playing: Bool) {
        time = t
        let label = Self.fmt(t)
        if timeLabel.stringValue != label {          // only when the second changes
            timeLabel.stringValue = label
            scrubber.timeText = "\(label) of \(Self.fmt(duration))"
        }
        scrubber.progress = duration > 0 ? t / duration : 0
        let name = playing ? "pause.fill" : "play.fill"
        if play.image?.accessibilityDescription != name {
            play.image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        }
    }

    func setRate(_ r: Float) {
        rateButton.attributedTitle = NSAttributedString(string: PlayerView.label(r), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: r == 1 ? NSColor(white: 1, alpha: 0.75) : NSColor.systemYellow])
        needsLayout = true
    }

    @objc private func tapPlay() { onPlay?() }
    @objc private func tapRate() { onRate?() }
    @objc private func tapMute() { onMute?() }
    @objc private func slideVolume() { onVolume?(Float(volume.doubleValue)) }

    /// Slider at the level, speaker glyph for the level (crossed out when muted).
    func setVolume(_ v: Float, muted: Bool) {
        if abs(volume.doubleValue - Double(v)) > 0.001 { volume.doubleValue = Double(v) }
        let name = muted || v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        if muteButton.image?.accessibilityDescription != name {
            muteButton.image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        }
        muteButton.setAccessibilityLabel(muted ? "Unmute" : "Mute")
        muteButton.toolTip = muted ? "Unmute (M)" : "Mute (M)"
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

final class Scrubber: NSView {
    var onBegin: (() -> Void)?
    var onMove: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onStep: ((Double) -> Void)?           // VoiceOver increment/decrement: seconds to skip
    var onHover: ((Double?) -> Void)?         // pointer over the bar (or dragging): position 0...1, nil when gone
    private var pressed = false
    var timeText = "0:00"                     // spoken value, e.g. "1:23 of 16:10"
    var progress: Double = 0 {
        didSet { if abs(progress - oldValue) * Double(bounds.width) >= 0.5 { needsDisplay = true } }   // redraw only on a visible move
    }
    private var hover: CGFloat?
    /// Progress runs right-to-left in RTL languages (HIG: flip progress controls).
    private var rtl: Bool { userInterfaceLayoutDirection == .rightToLeft }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Playback position")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? { timeText }
    override func accessibilityPerformIncrement() -> Bool { onStep?(rtl ? -5 : 5); return true }
    override func accessibilityPerformDecrement() -> Bool { onStep?(rtl ? 5 : -5); return true }

    private func fraction(_ e: NSEvent) -> Double {
        let x = convert(e.locationInWindow, from: nil).x
        let f = Double(max(0, min(1, (x - 6) / (bounds.width - 12))))
        return rtl ? 1 - f : f
    }

    override func mouseDown(with e: NSEvent) { pressed = true; onBegin?(); progress = fraction(e); onMove?(progress); onHover?(progress) }
    override func mouseDragged(with e: NSEvent) { progress = fraction(e); onMove?(progress); onHover?(progress) }
    override func mouseUp(with e: NSEvent) {
        pressed = false
        onEnd?()
        if !bounds.contains(convert(e.locationInWindow, from: nil)) { hover = nil; needsDisplay = true; onHover?(nil) }
    }
    override func mouseMoved(with e: NSEvent) { hover = convert(e.locationInWindow, from: nil).x; needsDisplay = true; onHover?(fraction(e)) }
    override func mouseExited(with e: NSEvent) { guard !pressed else { return }; hover = nil; needsDisplay = true; onHover?(nil) }

    /// Where position `f` sits along the bar, in this view's coordinates.
    func x(at f: Double) -> CGFloat { 6 + (bounds.width - 12) * CGFloat(rtl ? 1 - f : f) }

    override func draw(_ r: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let h: CGFloat = hover != nil ? 6 : 4
        let track = NSRect(x: 6, y: bounds.midY - h / 2, width: bounds.width - 12, height: h)
        NSColor(white: 1, alpha: contrast ? 0.5 : 0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        var done = track; done.size.width *= progress
        if rtl { done.origin.x = track.maxX - done.width }
        NSColor.white.setFill()
        NSBezierPath(roundedRect: done, xRadius: h / 2, yRadius: h / 2).fill()
        if hover != nil {
            let kx = rtl ? done.minX : done.maxX
            let k = NSRect(x: kx - 6, y: bounds.midY - 6, width: 12, height: 12)
            NSBezierPath(ovalIn: k).fill()
        }
    }
}

// MARK: - Formats AVFoundation won't open (MKV, WebM, AVI…): fast stream copy into MP4 via ffmpeg.

enum Remuxer {
    static func remux(_ url: URL) async -> URL? {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile) else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Flick")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.path)|\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let hash = Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let out = dir.appendingPathComponent(hash + ".mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let tmp = out.deletingPathExtension().appendingPathExtension("partial.mp4")   // AVFoundation needs a real extension
        for audio in [["-c:a", "copy"], ["-c:a", "aac", "-b:a", "192k"]] { for tag in [["-tag:v", "hvc1"], []] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-y", "-v", "error", "-i", url.path, "-map", "0:v:0", "-map", "0:a?", "-c:v", "copy"]
                + tag + audio + ["-sn", "-f", "mp4", tmp.path]
            let code: Int32 = await withCheckedContinuation { c in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { c.resume(returning: -1) }
            }
            if code == 0, (try? await AVURLAsset(url: tmp).load(.isPlayable)) == true {
                try? FileManager.default.moveItem(at: tmp, to: out)
                return out
            }
        } }
        return nil
    }
}


// MARK: - Volume badge (bottom right)

/// Speaker glyph, percentage and a thin level bar, shown bottom-right while volume changes.
final class VolumeBadge: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let level = CALayer()
    private let levelTrack = CALayer()
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        layer?.cornerRadius = 10
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .right
        levelTrack.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor
        levelTrack.cornerRadius = 1.5
        level.backgroundColor = NSColor.white.cgColor
        level.cornerRadius = 1.5
        addSubview(icon); addSubview(label)
        layer?.addSublayer(levelTrack); layer?.addSublayer(level)
        alphaValue = 0
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ v: Float, muted: Bool, in host: NSRect) {
        let pct = Int((v * 100).rounded())
        let name = muted || pct == 0 ? "speaker.slash.fill" : pct < 34 ? "speaker.wave.1.fill" : pct < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        label.stringValue = muted ? "Muted" : "\(pct)%"
        let w: CGFloat = 112, h: CGFloat = 34
        // bottom right, clear of the control bar
        frame = NSRect(x: host.maxX - w - 16, y: 72, width: w, height: h)
        icon.frame = NSRect(x: 10, y: 9, width: 22, height: 16)
        label.frame = NSRect(x: 34, y: 9, width: w - 44, height: 16)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        levelTrack.frame = NSRect(x: 10, y: 5, width: w - 20, height: 3)
        level.frame = NSRect(x: 10, y: 5, width: (w - 20) * CGFloat(muted ? 0 : v), height: 3)
        CATransaction.commit()
        alphaValue = 1
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: muted ? "Muted" : "Volume \(pct) percent", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self?.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
