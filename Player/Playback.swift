import AVFoundation

/// What the player view needs from a playback backend. MP4/MOV use AVPlayer; Matroska uses the native
/// pipeline below. Either way the scrub engine handles seeking while the user interacts.
protocol Playback: AnyObject {
    var layer: CALayer { get }
    var isPlaying: Bool { get }
    var currentSeconds: Double { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    func play(rate: Float)
    func pause()
    func setRate(_ r: Float)
    /// Move to an exact time; completion runs on main once that picture is on the backend's own layer.
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void)
    func cancelSeeks()
    func teardown()
    /// Release the video decoder while paused (it holds ~190 MB of 4K frame buffers). The next seek or
    /// play rebuilds it; the caller keeps the current picture on screen meanwhile.
    func suspend()
    var isSuspended: Bool { get }
}

// MARK: - AVPlayer

final class AVPlayerPlayback: Playback {
    let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let asset: AVURLAsset
    private(set) var isSuspended = false
    private var savedTime = CMTime.zero
    /// The subtitle group, so a suspend/revive (which swaps in a fresh item) keeps the chosen subtitles.
    var legibleGroup: AVMediaSelectionGroup?
    private var savedLegible: AVMediaSelectionOption?
    var layer: CALayer { playerLayer }

    init(asset: AVURLAsset) {
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }

    var isPlaying: Bool { player.rate != 0 }
    var currentSeconds: Double { isSuspended ? savedTime.seconds : player.currentTime().seconds }

    func suspend() {
        guard !isSuspended else { return }
        savedTime = player.currentTime()
        if let g = legibleGroup { savedLegible = player.currentItem?.currentMediaSelection.selectedMediaOption(in: g) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isSuspended = true
    }

    private func revive() {
        guard isSuspended else { return }
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        if let g = legibleGroup { item.select(savedLegible, in: g) }
        player.replaceCurrentItem(with: item)
        isSuspended = false
    }
    var volume: Float { get { player.volume } set { player.volume = newValue } }
    var isMuted: Bool { get { player.isMuted } set { player.isMuted = newValue } }

    func play(rate: Float) {
        if isSuspended {
            revive()
            player.seek(to: savedTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { self?.player.playImmediately(atRate: rate) }
            }
            return
        }
        if let item = player.currentItem, item.currentTime() >= item.duration - CMTime(value: 1, timescale: 10) {
            player.seek(to: .zero)
        }
        player.playImmediately(atRate: rate)
    }
    func pause() { player.pause() }
    func setRate(_ r: Float) { player.defaultRate = r; if player.rate != 0 { player.rate = r } }
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        revive()
        let go = { [player] in
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 90000), toleranceBefore: .zero, toleranceAfter: .zero) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        }
        // a just-revived item can report a seek as unfinished if it isn't ready yet: seek once it is
        guard let item = player.currentItem, item.status != .readyToPlay else { go(); return }
        var token: NSKeyValueObservation?
        var fired = false
        let fire = { DispatchQueue.main.async { guard !fired else { return }; fired = true; token?.invalidate(); token = nil; go() } }
        token = item.observe(\.status) { item, _ in if item.status != .unknown { fire() } }
        if item.status != .unknown { fire() }          // became ready (or failed) before the observer was in place
    }
    func cancelSeeks() { player.currentItem?.cancelPendingSeeks() }
    func teardown() { player.pause() }
}

// MARK: - Native (Matroska)

/// Compressed video and audio straight from the MKV packet table into Apple's sample-buffer renderers,
/// both slaved to one render synchronizer. Speed changes are a synchronizer rate change; the audio
/// renderer time-stretches with pitch correction.
final class NativePlayback: Playback {
    private let mkv: MKVFile
    private let index: MediaIndex
    private var display = AVSampleBufferDisplayLayer()
    private(set) var isSuspended = false
    private weak var host: CALayer?
    private let audio = AVSampleBufferAudioRenderer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private let q = DispatchQueue(label: "flick.native.feed", qos: .userInitiated)
    private let audioTrack: MKVFile.Track?
    private let audioFormat: CMAudioFormatDescription?
    private let audioIsPCM: Bool
    private let audioPackets: [MKVFile.Packet]
    private let tscale: Double                     // seconds per MKV timestamp unit
    private var vNext = 0                          // decode index of next video sample to enqueue
    private var aNext = 0
    private var hideBefore: Int64 = .min           // video pts below this are decoded but not shown (exact seek)
    private var gen = 0
    private var flushedGen = -1                    // generation whose renderer flush has completed
    private var endTimer: Timer?
    private(set) var isPlaying = false
    private var rate: Float = 1
    let duration: Double
    var onEnd: (() -> Void)?

    var layer: CALayer { display }

    init(mkv: MKVFile, index: MediaIndex) {
        self.mkv = mkv
        self.index = index
        tscale = Double(mkv.timecodeScale) / 1e9
        duration = index.duration
        let tracks = mkv.audioTracks
        let chosen = tracks.first { $0.isDefault && MKVCodecs.audioFormat($0) != nil } ?? tracks.first { MKVCodecs.audioFormat($0) != nil }
        audioTrack = chosen
        let fmt = chosen.flatMap(MKVCodecs.audioFormat)
        audioFormat = fmt?.0
        audioIsPCM = fmt?.isPCM ?? false
        audioPackets = chosen.flatMap { mkv.packets[$0.number] } ?? []
        display.videoGravity = .resizeAspect
        audio.audioTimePitchAlgorithm = .spectral
        sync.addRenderer(display.sampleBufferRenderer)
        if audioFormat != nil { sync.addRenderer(audio) }
        sync.delaysRateChangeUntilHasSufficientMediaData = false
        start(at: 0)
    }

    /// Whether this file has audio the system can't decode (the caller may prefer the remuxer then).
    static func hasUndecodableAudioOnly(_ mkv: MKVFile) -> Bool {
        !mkv.audioTracks.isEmpty && mkv.audioTracks.allSatisfy { MKVCodecs.audioFormat($0) == nil }
    }

    var currentSeconds: Double { max(0, sync.currentTime().seconds - Double(index.startPTS) / Double(index.timescale)) }
    var volume: Float { get { audio.volume } set { audio.volume = newValue } }
    var isMuted: Bool { get { audio.isMuted } set { audio.isMuted = newValue } }

    func suspend() {
        guard !isSuspended else { return }
        pause()
        q.sync { gen &+= 1 }
        display.sampleBufferRenderer.stopRequestingMediaData()
        audio.stopRequestingMediaData()
        display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audio.flush()
        sync.removeRenderer(display.sampleBufferRenderer, at: sync.currentTime(), completionHandler: nil)
        // a display layer keeps its decoder (and its frame pool) until the layer itself goes away
        host = display.superlayer
        let frame = display.frame
        display.removeFromSuperlayer()
        display = AVSampleBufferDisplayLayer()
        display.videoGravity = .resizeAspect
        display.frame = frame
        isSuspended = true
    }

    private func revive() {
        guard isSuspended else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host?.insertSublayer(display, at: 0)
        CATransaction.commit()
        sync.addRenderer(display.sampleBufferRenderer)
        isSuspended = false
    }

    func play(rate r: Float) {
        if isSuspended {
            let t = currentSeconds
            revive()
            start(at: t) { [weak self] _ in self?.play(rate: r) }
            return
        }
        rate = r
        if currentSeconds >= duration - 0.05 { seek(to: 0) { _ in } }
        isPlaying = true
        sync.setRate(r, time: sync.currentTime())
        startEndWatch()
    }

    func pause() {
        isPlaying = false
        sync.rate = 0
        endTimer?.invalidate()
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { sync.rate = r }
    }

    func cancelSeeks() { q.async { self.gen &+= 1 } }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        revive()
        let wasPlaying = isPlaying
        sync.rate = 0
        start(at: seconds) { [weak self] ok in
            guard let self else { return }
            if wasPlaying && self.isPlaying { self.sync.setRate(self.rate, time: self.sync.currentTime()) }
            completion(ok)
        }
    }

    func teardown() {
        pause()
        q.sync { gen &+= 1 }
        display.sampleBufferRenderer.stopRequestingMediaData()
        audio.stopRequestingMediaData()
    }

    // MARK: feeding

    private func pts(_ p: Int64) -> CMTime { CMTime(value: p, timescale: index.timescale) }

    /// Flush both renderers and restart feeding from the keyframe before `seconds`; frames before the
    /// target are decoded but never shown, so the first picture is the exact one.
    private func start(at seconds: Double, completion: ((Bool) -> Void)? = nil) {
        let d = index.frame(at: min(max(0, seconds), duration))
        let targetPTS = index.samples[d].pts
        let start = index.gopStart(for: d)
        q.async { [self] in
            gen &+= 1
            let g = gen
            display.sampleBufferRenderer.stopRequestingMediaData()
            audio.stopRequestingMediaData()
            // The hand-off back from the scrub layer waits for this flush to land, then for a picture:
            // displayedPixelBuffer() hands out a new object each call, so comparing identities proves nothing.
            flushedGen = -1
            display.sampleBufferRenderer.flush(removingDisplayedImage: true) { [weak self] in
                self?.q.async { self?.flushedGen = g }
            }
            audio.flush()
            sync.setRate(0, time: pts(targetPTS))
            vNext = start
            hideBefore = targetPTS
            let at = Double(targetPTS) / Double(index.timescale) - 0.05
            aNext = audioPackets.firstIndex { Double($0.pts) * tscale >= at } ?? audioPackets.count
            display.sampleBufferRenderer.requestMediaDataWhenReady(on: q) { [weak self] in self?.feedVideo(g) }
            if audioFormat != nil { audio.requestMediaDataWhenReady(on: q) { [weak self] in self?.feedAudio(g) } }
            if let completion { waitForPicture(g, deadline: CACurrentMediaTime() + 2, completion) }
        }
    }

    private func waitForPicture(_ g: Int, deadline: Double, _ completion: @escaping (Bool) -> Void) {
        guard g == gen else { DispatchQueue.main.async { completion(false) }; return }
        let shown: Bool
        if #available(macOS 14.4, *) {
            shown = flushedGen == g && display.sampleBufferRenderer.displayedPixelBuffer() != nil
        }
        else { shown = CACurrentMediaTime() > deadline - 1.85 }
        if shown || CACurrentMediaTime() > deadline {
            DispatchQueue.main.async { completion(true) }
            return
        }
        q.asyncAfter(deadline: .now() + 0.004) { [weak self] in self?.waitForPicture(g, deadline: deadline, completion) }
    }

    private func feedVideo(_ g: Int) {
        let r = display.sampleBufferRenderer
        while g == gen && r.isReadyForMoreMediaData && vNext < index.samples.count {
            let s = index.samples[vNext]
            vNext += 1
            guard let sb = index.sampleBuffer(vNext - 1) else { continue }
            if s.pts < hideBefore, let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
                a.first?[kCMSampleAttachmentKey_DoNotDisplay] = true
            }
            r.enqueue(sb)
        }
        if vNext >= index.samples.count { r.stopRequestingMediaData() }
    }

    private func feedAudio(_ g: Int) {
        guard let fmt = audioFormat else { return }
        while g == gen && audio.isReadyForMoreMediaData && aNext < audioPackets.count {
            let p = audioPackets[aNext]
            aNext += 1
            if let sb = audioBuffer(p, fmt) { audio.enqueue(sb) }
        }
        if aNext >= audioPackets.count { audio.stopRequestingMediaData() }
    }

    private func audioBuffer(_ p: MKVFile.Packet, _ fmt: CMAudioFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: UnsafeMutableRawPointer(mutating: mkv.base + Int(p.offset)),
                                                 blockLength: Int(p.size), blockAllocator: kCFAllocatorNull, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: Int(p.size), flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let t = CMTime(seconds: Double(p.pts) * tscale, preferredTimescale: 48000)
        var sb: CMSampleBuffer?
        if audioIsPCM {
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee, asbd.mBytesPerFrame > 0 else { return nil }
            let frames = Int(p.size) / Int(asbd.mBytesPerFrame)
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt,
                                                                 sampleCount: frames, presentationTimeStamp: t,
                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
        } else {
            var pd = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(p.size))
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt,
                                                                 sampleCount: 1, presentationTimeStamp: t,
                                                                 packetDescriptions: &pd, sampleBufferOut: &sb)
        }
        return sb
    }

    private func startEndWatch() {
        endTimer?.invalidate()
        defer { endTimer?.tolerance = 0.1 }
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            Trace.log(String(format: "native t=%.2f audio=%d err=%@ video=%d aNext=%d vNext=%d", self.currentSeconds,
                             self.audio.status.rawValue, String(describing: self.audio.error), self.display.sampleBufferRenderer.status.rawValue,
                             self.aNext, self.vNext))
            if self.currentSeconds >= self.duration - 0.02 {
                self.pause()
                self.onEnd?()
            }
        }
    }
}
