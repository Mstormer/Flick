import AppKit
import AVFoundation
import MediaAccessibility
import UniformTypeIdentifiers

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [PlayerWindowController] = []
    private var openedAny = false

    func applicationWillFinishLaunching(_ n: Notification) {
        // 0.2.2 and earlier kept ffmpeg remux copies here
        try? FileManager.default.removeItem(at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Flick"))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !args.isEmpty { open(args.map { URL(fileURLWithPath: $0) }) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if !openedAny { openDocument(nil) }
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) { open(urls) }

    /// Several files, or any folder, open as one window with a playlist; a single file opens on its own.
    func open(_ urls: [URL]) {
        guard urls.count > 1 || urls.first?.hasDirectoryPath == true || urls.first.map(isFolder) == true else {
            if let u = urls.first { open(u) }
            return
        }
        let items = Playlist.expand(urls)
        guard !items.isEmpty else { return }
        openedAny = true
        urls.forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
        let wc = PlayerWindowController(urls: items)
        windows.append(wc)
        wc.onClose = { [weak self, weak wc] in self?.windows.removeAll { $0 === wc } }
        wc.showWindow(nil)
    }

    private func isFolder(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { windows.forEach { $0.view.savePosition() } }

    @objc func clearPlaybackCache(_ s: Any?) { PlaybackMemory.clear() }

    func open(_ url: URL) {
        if isFolder(url) { open([url]); return }
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
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        if p.runModal() == .OK, !p.urls.isEmpty { open(p.urls) }
    }

    private func buildMenu() { NSApp.mainMenu = MainMenu.build(self) }
}

// MARK: - Window

final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// The player for the current video; a new one per video, so nothing carries over by accident.
    private(set) var view: PlayerView
    private let host = PlayerHost()
    private let list = PlaylistPanel()
    private(set) var items: [URL]
    private(set) var current: Int
    private var infoShown = false
    var url: URL { items[current] }

    convenience init(url: URL) { self.init(urls: [url]) }

    init(urls: [URL], start: Int = 0) {
        items = urls
        current = start
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
        host.frame = NSRect(origin: .zero, size: rect.size)
        win.contentView = host
        view = PlayerView(frame: host.bounds)
        super.init(window: win)
        win.delegate = self
        host.list = list
        host.addSubview(list)
        host.onDrop = { [weak self] urls in self?.replace(with: urls) }
        list.onPick = { [weak self] i in self?.play(i) }
        list.set(items, current: current)
        list.isHidden = items.count < 2
        install(view)
        view.load(url)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func install(_ v: PlayerView) {
        v.frame = host.bounds
        v.autoresizingMask = [.width, .height]
        host.addSubview(v, positioned: .below, relativeTo: list)
        v.onSwitch = { [weak self] by in self?.step(by) }
        v.playlistCount = { [weak self] in self?.items.count ?? 1 }
        v.playlistVisible = { [weak self] in self?.list.isHidden == false }
        v.onTogglePlaylist = { [weak self] in self?.togglePlaylist() }
        v.onFinished = { [weak self] in
            guard let self, self.current + 1 < self.items.count else { return }
            self.play(self.current + 1, autoplay: true)
        }
        v.onInfoToggled = { [weak self] on in self?.infoShown = on }
        v.onChrome = { [weak self] on, d in
            guard let list = self?.list, list.alphaValue != (on ? 1 : 0) else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = d; list.animator().alphaValue = on ? 1 : 0 }
        }
        v.pointerOverOverlay = { [weak self] in
            guard let list = self?.list, !list.isHidden, list.alphaValue > 0, let w = list.window else { return false }
            return list.frame.contains(list.superview!.convert(w.mouseLocationOutsideOfEventStream, from: nil))
        }
        window?.title = url.lastPathComponent
        window?.makeFirstResponder(v)
    }

    /// Switch to another video in the list, keeping volume, mute and the info panel as they were. If the
    /// player was paused it stays paused, and the new video isn't opened until Play.
    func play(_ i: Int, autoplay: Bool? = nil) {
        guard items.indices.contains(i) else { return }
        let old = view
        let playing = autoplay ?? old.isPlayingNow
        let sound = old.soundState
        old.teardown()
        old.removeFromSuperview()
        current = i
        let v = PlayerView(frame: host.bounds)
        v.startSound = sound
        v.startInfo = infoShown
        view = v
        install(v)
        list.select(i)
        if playing {
            v.load(url)
            if list.isHidden { v.announce("\(i + 1) of \(items.count): \(url.deletingPathExtension().lastPathComponent)") }
        } else {
            v.prepare(url)
        }
    }

    private func step(_ by: Int) {
        let i = current + by
        guard items.indices.contains(i) else { NSSound.beep(); return }
        play(i)
    }

    func togglePlaylist() {
        guard items.count > 1 else { return }
        list.isHidden.toggle()
        host.needsLayout = true
        updateMenuKeys()
        if !list.isHidden { view.reveal() }
    }

    /// Files or folders dropped on the window become its playlist.
    private func replace(with urls: [URL]) {
        let found = Playlist.expand(urls)
        guard !found.isEmpty else { return }
        urls.forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
        items = found
        list.set(items, current: 0)
        list.isHidden = items.count < 2
        host.needsLayout = true
        updateMenuKeys()
        current = 0
        play(0, autoplay: true)
    }

    private func updateMenuKeys() { MainMenu.setPlaylistMode(items.count > 1, visible: !list.isHidden) }
    func windowDidBecomeKey(_ n: Notification) { updateMenuKeys() }
    func windowWillClose(_ n: Notification) { view.teardown(); onClose?() }
}

/// The window's content: the player, the playlist over its right side, and the drop target for files.
final class PlayerHost: NSView {
    weak var list: PlaylistPanel?
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // top left, clear of the title bar above and the control bar below (file info goes top right)
        guard let list else { return }
        let w = min(PlaylistPanel.width, bounds.width * 0.4)
        let h = max(60, list.fittingHeight(bounds.height - 76 - 40))
        list.frame = NSRect(x: 12, y: bounds.height - 40 - h, width: w, height: h)
    }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { urls(info).isEmpty ? [] : .copy }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let u = urls(info)
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}

// MARK: - Player view

final class PlayerView: NSView {
    private(set) var backend: Playback?
    private let videoHost = CALayer()          // the backend's own layer goes in here
    private let scrubLayer = AVSampleBufferDisplayLayer()
    private let controls = ControlBar()
    private let hud = BadgeLabel()
    private let volumeBadge = VolumeBadge()
    private let previewBubble = PreviewBubble()
    private var previewSource: PreviewSource?
    private let captionOverlay = CaptionOverlay()
    private var mkv: MKVFile?
    private(set) var captionSources: [CaptionSource] = []
    private(set) var captionChoice: Int?                 // index into captionSources; nil = off
    private var lastCaptionChoice = 0
    private let status = BadgeLabel()
    private let infoPanel = InfoPanel()
    private var infoTask: Task<Void, Never>?
    private var loadedURL: URL?
    /// Chosen in the playlist while paused: shown as black with its name, opened only when Play is pressed,
    /// so arrowing through a list doesn't open every file on the way.
    private var pendingURL: URL?
    private var endObserver: NSObjectProtocol?

    // the window's playlist (PlayerWindowController owns it)
    var onSwitch: ((Int) -> Void)?
    var playlistCount: () -> Int = { 1 }
    var playlistVisible: () -> Bool = { false }
    var onTogglePlaylist: (() -> Void)?
    var onFinished: (() -> Void)?
    var onInfoToggled: ((Bool) -> Void)?
    /// The window's overlays (playlist) fade in and out with the controls; nil duration = at once.
    var onChrome: ((Bool, Double) -> Void)?
    var pointerOverOverlay: () -> Bool = { false }
    /// Carried over from the previous video in the list.
    var startSound: (volume: Float, muted: Bool)?
    /// Test harnesses set this so nothing they open is heard (the audio still runs, just silent).
    static var startMuted = false
    var startInfo = false
    var soundState: (volume: Float, muted: Bool)? { backend.map { ($0.volume, $0.isMuted) } ?? startSound }
    /// Playing, or about to (still opening, or mid-seek with play to resume).
    var isPlayingNow: Bool {
        guard pendingURL == nil else { return false }
        guard let backend else { return loadedURL != nil }
        return target != nil ? resumeAfterSeek : backend.isPlaying
    }

    /// Stand in for `url` without opening it: black, its name, and the info panel if that's open.
    func prepare(_ url: URL) {
        pendingURL = url
        loadedURL = url
        controls.duration = 0
        controls.setTime(0, playing: false)
        showControls()
        flash(status, url.deletingPathExtension().lastPathComponent, hold: true)
        if startInfo { setInfo(true) }
    }

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
        addSubview(infoPanel)
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
        let ih = infoPanel.fittingHeight
        let iw = min(InfoPanel.width, bounds.width - 24)
        infoPanel.frame = NSRect(x: bounds.width - iw - 12, y: max(76, bounds.height - 40 - ih), width: iw, height: ih)
    }

    // MARK: loading

    func load(_ url: URL) {
        loadedURL = url
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
                    native.onEnd = { [weak self] in self?.controls.setTime(self?.duration ?? 0, playing: false); self?.finished() }
                    backend = native
                    newIndex = idx
                    duration = idx.duration
                } else {
                    let av = AVPlayerPlayback(asset: asset)
                    backend = av
                    duration = (try? await asset.load(.duration).seconds) ?? 0
                    endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self, weak av] n in
                        guard let av, (n.object as? AVPlayerItem) === av.player.currentItem else { return }
                        self?.finished()
                    }
                }
                size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            } else if let (mkv, idx) = await Task.detached(operation: { () -> (MKVFile, MediaIndex?)? in
                          // Matroska natively: parse, index, and play without a demuxer library
                          guard let m = MKVFile(url: url), m.video != nil else { return nil }
                          guard let i = MediaIndex(mkv: m), ScrubEngine.canDecode(i) else { return (m, nil) }
                          return (m, i)
                      }).value, let idx {
                let native = NativePlayback(mkv: mkv, index: idx)
                native.onEnd = { [weak self] in self?.controls.setTime(self?.duration ?? 0, playing: false); self?.finished() }
                backend = native
                newIndex = idx
                self.mkv = mkv
                duration = idx.duration
                let v = mkv.video!
                size = CGSize(width: v.displayWidth > 0 ? v.displayWidth : v.width, height: v.displayHeight > 0 ? v.displayHeight : v.height)
            } else {
                // WMV, VC-1, VP9 the hardware decoder refuses…: decoded in software by the bundled FFmpeg
                let mkv = MKVFile(url: url)
                guard let (v, a) = await Task.detached(operation: { FFPlayback.open(url, audio: mkv.flatMap(MKVCodecs.audioSource)) }).value
                else { flash(status, "Can't open this file"); return }
                let ff = FFPlayback(video: v, audio: a)
                ff.onEnd = { [weak self] in self?.controls.setTime(self?.duration ?? 0, playing: false); self?.finished() }
                backend = ff
                self.mkv = mkv
                duration = ff.duration
                size = ff.displaySize
                previewSource = FFThumbnailer(url: url)
            }
            guard let backend else { return }
            if let s = startSound { backend.volume = s.volume; backend.isMuted = s.muted }
            if Self.startMuted { backend.isMuted = true }
            if startInfo || !infoPanel.isHidden {
                infoTask?.cancel(); infoTask = nil         // read again, now that the decoder is known
                setInfo(true)
            }
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
            if let t = PlaybackMemory.position(for: url, duration: duration) {
                // where it was left last time
                controls.setTime(t, playing: true)
                flash(status, "Resuming at \(ControlBar.fmt(t))")
                backend.seek(to: t) { [weak self, weak backend] _ in
                    guard let self, let backend, self.backend === backend else { return }
                    backend.play(rate: self.rate)
                }
            } else {
                backend.play(rate: rate)
            }
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
                previewSource = Thumbnailer(index: idx)
            }
        }
    }

    /// UI clock. 30 Hz only while something on screen moves with it (visible controls, captions);
    /// otherwise 4 Hz, with timer tolerance so macOS can coalesce wakeups. Saves energy during playback.
    private func tick() {
        if CACurrentMediaTime() - lastSaved > 5, backend?.isPlaying == true { savePosition() }
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

    private func finished() {
        if let u = loadedURL { PlaybackMemory.forget(u) }
        onFinished?()
    }

    /// Remember where this video is (Playback › Clear Playback Cache forgets).
    func savePosition() {
        guard pendingURL == nil, let url = loadedURL, let b = backend, duration > 0 else { return }
        lastSaved = CACurrentMediaTime()
        PlaybackMemory.save(url, at: currentFrame.flatMap { index?.seconds($0) } ?? b.currentSeconds, duration: duration)
    }
    private var lastSaved = 0.0

    func teardown() {
        savePosition()
        infoTask?.cancel()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
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
        guard pendingURL == nil else { return }
        let base = currentFrame.flatMap { index?.seconds($0) } ?? backend?.currentSeconds ?? 0
        seek(seconds: base + by, settleAfter: 0.25)
    }

    private func stepFrame(_ n: Int) {
        guard pendingURL == nil else { return }
        if index == nil, let ff = backend as? FFPlayback { ff.step(n); return }
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
        if let u = pendingURL {
            pendingURL = nil
            status.alphaValue = 0
            load(u)                                     // opens and plays
            return
        }
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
        if isPlayingNow { scheduleHide() } else { chrome(true, 0.12); savePosition() }
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
        guard let th = previewSource else { return }
        th.spacing = dragging ? 0.08 : 0          // leave the decoder to the main picture while dragging
        th.request(seconds: t) { [weak self] img, k in
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
    @objc func nextVideo(_ s: Any?) { onSwitch?(1) }
    @objc func previousVideo(_ s: Any?) { onSwitch?(-1) }
    @objc func togglePlaylist(_ s: Any?) { onTogglePlaylist?() }
    @objc func toggleInfo(_ s: Any?) { setInfo(infoPanel.isHidden) }
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
        case #selector(togglePlay) where pendingURL != nil:
            item.title = "Play"
            return true
        case #selector(togglePlay):
            let playing = target != nil ? resumeAfterSeek : backend?.isPlaying ?? false
            item.title = playing ? "Pause" : "Play"
        case #selector(toggleMute(_:)): item.title = backend?.isMuted == true ? "Unmute" : "Mute"
        case #selector(toggleControllerVisibility(_:)): item.title = controlsHiddenByUser ? "Show Controls" : "Hide Controls"
        case #selector(nextVideo(_:)), #selector(previousVideo(_:)): return playlistCount() > 1
        case #selector(togglePlaylist(_:)):
            item.title = playlistVisible() ? "Hide Playlist" : "Show Playlist"
            return playlistCount() > 1
        case #selector(toggleInfo(_:)):
            item.title = infoPanel.isHidden ? "Show Info" : "Hide Info"
            return loadedURL != nil
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

    /// The arrow keys are the player's: take them before the menu bar, so a menu item can never swallow
    /// them (Previous/Next Video and Volume share them, depending on whether the playlist shows).
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, (123...126).contains(e.keyCode),
              e.modifierFlags.intersection([.command, .control]).isEmpty else { return super.performKeyEquivalent(with: e) }
        keyDown(with: e)
        return true
    }

    override func keyDown(with e: NSEvent) {
        if let sc = Shortcuts.shared.match(e) { perform(sc); return }
        let shift = e.modifierFlags.contains(.shift)
        let alt = e.modifierFlags.contains(.option)
        switch e.keyCode {
        case 123: skip(shift ? -1 : alt ? -30 : -5)
        case 124: skip(shift ? 1 : alt ? 30 : 5)
        // while the list is showing, up/down move through it (Option: volume); hidden, the other way round
        case 126: if playlistCount() > 1 && playlistVisible() != alt { onSwitch?(-1) } else { changeVolume(0.05) }
        case 125: if playlistCount() > 1 && playlistVisible() != alt { onSwitch?(1) } else { changeVolume(-0.05) }
        case 49: togglePlay()
        case 116 where shift: skip(600)
        case 121 where shift: skip(-600)
        case 53: if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        default:
            switch e.charactersIgnoringModifiers {
            case ",": stepFrame(-1)
            case ".": stepFrame(1)
            case "f": window?.toggleFullScreen(nil)
            case "i": toggleInfo(nil)
            case "\\", "l": onTogglePlaylist?()
            case "m": if let b = backend { b.isMuted.toggle(); flash(hud, b.isMuted ? "Muted" : "Sound"); controls.setVolume(b.volume, muted: b.isMuted) }
            case "]": faster()
            case "[": slower()
            case "\u{7f}": normalSpeed()
            case let c? where Int(c).map({ (1...4).contains($0) }) == true: setRate(Float(Int(c)!))
            default: super.keyDown(with: e)
            }
        }
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { window?.toggleFullScreen(nil) } else { super.mouseDown(with: e) }
    }

    override func scrollWheel(with e: NSEvent) {
        // Two fingers right = forward, whatever the natural-scrolling setting.
        if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) {
            let right = Double(e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX)
            skip(right * (e.hasPreciseScrollingDeltas ? 0.05 : 1))
            return
        }
        // Two fingers up = louder, whatever the natural-scrolling setting; ignore the momentum tail.
        guard e.momentumPhase.isEmpty, e.scrollingDeltaY != 0 else { return }
        let up = Float(e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY)
        changeVolume(e.hasPreciseScrollingDeltas ? up * 0.003 : (up > 0 ? 0.05 : -0.05))
    }

    /// Pinch in / spread out: the window shrinks or grows around its centre, keeping the video's shape,
    /// from 320 pt wide up to the full width (or height) of the screen.
    override func magnify(with e: NSEvent) { zoomWindow(by: e.magnification) }

    func zoomWindow(by m: CGFloat) {
        guard let w = window, !w.styleMask.contains(.fullScreen), let screen = w.screen?.visibleFrame, m != 0 else { return }
        let f = w.frame
        let aspect = f.width / max(1, f.height)
        var width = min(max(f.width * (1 + m), 320), screen.width)
        var height = width / aspect
        if height > screen.height { height = screen.height; width = height * aspect }
        width = width.rounded(); height = height.rounded()
        var r = NSRect(x: (f.midX - width / 2).rounded(), y: (f.midY - height / 2).rounded(), width: width, height: height)
        r.origin.x = min(max(r.minX, screen.minX), screen.maxX - r.width)
        r.origin.y = min(max(r.minY, screen.minY), screen.maxY - r.height)
        w.setFrame(r, display: true)
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

    /// The playlist and the info panel: shown with the controls; while playing they fade with them.
    private func chrome(_ on: Bool, _ duration: Double) {
        onChrome?(on, duration)
        guard infoPanel.alphaValue != (on ? 1 : 0) else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = duration; infoPanel.animator().alphaValue = on ? 1 : 0 }
    }

    private func showControls() {
        NSCursor.setHiddenUntilMouseMoves(false)
        chrome(true, 0.12)
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
            guard let self, !self.dragging, !self.controls.isMouseInside, !self.overWindowButtons, !self.pointerOverOverlay() else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self.controls.animator().alphaValue = 0 }
            if self.isPlayingNow { self.chrome(false, 0.25) }   // paused: the list and info stay up
            self.previewBubble.show(false)
            self.setWindowButtons(visible: false, duration: 0.25)
            if self.window?.isKeyWindow == true { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    // MARK: file info

    /// What decodes this file, for the info panel.
    private var decoderName: String {
        switch backend {
        case let n as NativePlayback: return n.usesFFmpegAudio ? "Hardware video, FFmpeg audio" : "Hardware (VideoToolbox)"
        case is FFPlayback: return "Software (FFmpeg)"
        case is AVPlayerPlayback: return "AVFoundation"
        default: return "—"
        }
    }

    private func setInfo(_ on: Bool) {
        infoPanel.isHidden = !on
        onInfoToggled?(on)
        if on { showControls() }                       // up with the controls, fading with them while playing
        guard on, infoTask == nil, let url = loadedURL else { return }
        infoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let info = await MediaInfo.load(url, mkv: self.mkv, decoder: self.decoderName)
            guard !Task.isCancelled else { return }
            self.infoPanel.show(info)
            self.needsLayout = true
        }
    }

    /// Bring the controls and overlays up (then they fade again if playing).
    func reveal() { showControls() }

    /// A short message in the middle of the picture (the playlist's "3 of 12: name" when it's hidden).
    func announce(_ text: String) { flash(status, text) }

    private func flash(_ f: NSTextField, _ text: String, hold: Bool = false) {
        f.stringValue = text
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let w = min(max(90, f.attributedStringValue.size().width + 28), bounds.width - 40)
        f.lineBreakMode = .byTruncatingMiddle
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

/// A rounded message badge whose text sits in the middle of the box, vertically as well.
final class BadgeLabel: NSTextField {
    override class var cellClass: AnyClass? { get { CenteredCell.self } set {} }

    convenience init() {
        self.init(frame: .zero)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
    }

    final class CenteredCell: NSTextFieldCell {
        override func titleRect(forBounds r: NSRect) -> NSRect {
            var t = super.titleRect(forBounds: r)
            let h = cellSize(forBounds: r).height
            t.origin.y = r.minY + (r.height - h) / 2
            t.size.height = h
            return t
        }
        override func drawInterior(withFrame f: NSRect, in v: NSView) { super.drawInterior(withFrame: titleRect(forBounds: f), in: v) }
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
