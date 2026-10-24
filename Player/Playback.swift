import AVFoundation
import VideoToolbox

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
/// Audio for NativePlayback, from wherever the file keeps it. Used on the player's feed queue only.
protocol AudioSource: AnyObject {
    var format: CMAudioFormatDescription { get }
    /// Start over from just before `seconds` (on the video's timeline).
    func reset(at seconds: Double)
    /// The next buffer to play, or nil at the end.
    func next() -> CMSampleBuffer?
}

/// Matroska audio packets straight from the mapped file.
final class MKVAudio: AudioSource {
    let format: CMAudioFormatDescription
    private let mkv: MKVFile
    private let packets: [MKVFile.Packet]
    private let isPCM: Bool
    private let tscale: Double                     // seconds per MKV timestamp unit
    private var nextIndex = 0

    init?(_ mkv: MKVFile, track chosen: MKVFile.Track) {
        guard let f = MKVCodecs.audioFormat(chosen) else { return nil }
        self.mkv = mkv
        format = f.0
        isPCM = f.isPCM
        packets = mkv.packets[chosen.number] ?? []
        tscale = Double(mkv.timecodeScale) / 1e9
    }

    func reset(at seconds: Double) {
        nextIndex = packets.firstIndex { Double($0.pts) * tscale >= seconds } ?? packets.count
    }

    func next() -> CMSampleBuffer? {
        while nextIndex < packets.count {
            let p = packets[nextIndex]
            nextIndex += 1
            if let sb = buffer(p) { return sb }
        }
        return nil
    }

    private func buffer(_ p: MKVFile.Packet) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: UnsafeMutableRawPointer(mutating: mkv.base + Int(p.offset)),
                                                 blockLength: Int(p.size), blockAllocator: kCFAllocatorNull, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: Int(p.size), flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let t = CMTime(seconds: Double(p.pts) * tscale, preferredTimescale: 48000)
        var sb: CMSampleBuffer?
        if isPCM {
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mBytesPerFrame > 0 else { return nil }
            let frames = Int(p.size) / Int(asbd.mBytesPerFrame)
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                 sampleCount: frames, presentationTimeStamp: t,
                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
        } else {
            var pd = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(p.size))
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                 sampleCount: 1, presentationTimeStamp: t,
                                                                 packetDescriptions: &pd, sampleBufferOut: &sb)
        }
        return sb
    }
}

/// MP4/MOV audio, still compressed, through AVAssetReader (a new reader per seek).
final class AssetAudio: AudioSource {
    let format: CMAudioFormatDescription
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let shift: CMTime                      // movie time → the video's media timeline (edit lists)
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    init(asset: AVURLAsset, track: AVAssetTrack, format: CMAudioFormatDescription, shift: CMTime) {
        self.asset = asset
        self.track = track
        self.format = format
        self.shift = shift
    }

    func reset(at seconds: Double) {
        reader?.cancelReading()
        reader = nil; output = nil
        guard let r = try? AVAssetReader(asset: asset) else { return }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { return }
        r.add(o)
        let start = CMTimeSubtract(CMTime(seconds: max(0, seconds), preferredTimescale: 90000), shift)
        r.timeRange = CMTimeRange(start: CMTimeMaximum(.zero, start), end: .positiveInfinity)
        guard r.startReading() else { return }
        reader = r; output = o
    }

    func next() -> CMSampleBuffer? {
        guard let sb = output?.copyNextSampleBuffer() else { return nil }
        guard shift != .zero else { return sb }
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, CMSampleBufferGetNumSamples(sb)))
        var n = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: info.count, arrayToFill: &info, entriesNeededOut: &n) == noErr else { return sb }
        for i in 0..<n { info[i].presentationTimeStamp = CMTimeAdd(info[i].presentationTimeStamp, shift); info[i].decodeTimeStamp = .invalid }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: n, sampleTimingArray: &info, sampleBufferOut: &out)
        return out ?? sb
    }
}

final class NativePlayback: Playback {
    private let index: MediaIndex
    private var display = AVSampleBufferDisplayLayer()
    private(set) var isSuspended = false
    private weak var host: CALayer?
    private let audio = AVSampleBufferAudioRenderer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private let q = DispatchQueue(label: "flick.native.feed", qos: .userInitiated)
    private let audioSource: AudioSource?
    private var vNext = 0                          // decode index of next video sample to enqueue
    private var hideBefore: Int64 = .min           // video pts below this are decoded but not shown (exact seek)
    private var gen = 0
    private var flushedGen = -1                    // generation whose renderer flush has completed
    private var endTimer: Timer?
    private(set) var isPlaying = false
    private var rate: Float = 1
    let duration: Double
    var onEnd: (() -> Void)?
    // Video is decoded here rather than inside the display layer, so only a few frames are ever queued
    // (the layer decodes up to a second ahead: ~280 MB of 4K pictures). Everything below is on q.
    private var session: VTDecompressionSession?
    private var outFormat: CMVideoFormatDescription?
    private var inflight = 0                       // handed to the decoder, not out yet (this generation)
    private var queued: [Int64] = []               // pts of pictures the layer holds that aren't on screen yet
    // The decoder can hand B-frames back out of display order, and the layer drops a picture that arrives
    // behind a later one (15% of frames at 4x on H.264). Pictures wait here until nothing earlier is still out.
    private var outstanding: [Int64] = []          // pts of frames handed to the decoder, not out yet
    private var reorder: [(pts: Int64, time: CMTime, image: CVImageBuffer)] = []
    private var pumpPending = false
    private var audioTraced = -1
    private var targetQueuedGen = -1               // generation whose exact-seek target has reached the layer
    private var sessionBroken = false
    private let fps: Double
    /// Constant-rate video stored with coarse timestamps (Matroska's are whole milliseconds: 33, 34, 33…)
    /// gets presentation times on an even grid; at 4x the uneven ones beat against a 120 Hz display.
    private let grid: (first: Int64, step: Double)?

    var layer: CALayer { display }

    init(index: MediaIndex, audio source: AudioSource?) {
        self.index = index
        duration = index.duration
        audioSource = source
        let n = index.byPTS.count
        let first = index.samples[Int(index.byPTS[0])].pts
        let step = n > 1 ? Double(index.samples[Int(index.byPTS[n - 1])].pts - first) / Double(n - 1) : 0
        // constant rate: every timestamp within a quarter frame of the grid (checked over the first 600)
        let cfr = step > 0 && (0..<min(n, 600)).allSatisfy {
            abs(Double(index.samples[Int(index.byPTS[$0])].pts - first) - Double($0) * step) < step / 4
        }
        grid = cfr ? (first, step) : nil
        fps = cfr ? Double(index.timescale) / step : 1 / max(index.frameDuration, 0.001)
        display.videoGravity = .resizeAspect
        audio.audioTimePitchAlgorithm = .spectral
        sync.addRenderer(display.sampleBufferRenderer)
        if audioSource != nil { sync.addRenderer(audio) }
        sync.delaysRateChangeUntilHasSufficientMediaData = false
        start(at: 0)
    }

    convenience init(mkv: MKVFile, index: MediaIndex) {
        self.init(index: index, audio: MKVCodecs.audioSource(mkv))
    }

    /// A plain MP4/MOV (one video track, at most one audio track, no embedded subtitles, no rotation, SDR)
    /// plays here too; anything fancier stays with AVPlayer. `defaults write app.flick.player avplayer -bool YES`
    /// sends everything to AVPlayer.
    static func make(asset: AVURLAsset) async -> (NativePlayback, MediaIndex)? {
        guard !UserDefaults.standard.bool(forKey: "avplayer"),
              let videos = try? await asset.loadTracks(withMediaType: .video), videos.count == 1, let v = videos.first,
              let audios = try? await asset.loadTracks(withMediaType: .audio), audios.count <= 1,
              (try? await asset.loadMediaSelectionGroup(for: .legible))?.options.isEmpty ?? true,
              let transform = try? await v.load(.preferredTransform), transform.isIdentity,
              let vfmt = try? await v.load(.formatDescriptions).first
        else { return nil }
        let tf = CMFormatDescriptionGetExtension(vfmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) || tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return nil }
        var source: AudioSource?
        if let a = audios.first {
            guard let afmt = try? await a.load(.formatDescriptions).first else { return nil }
            let ok: [AudioFormatID] = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatAppleLossless,
                                       kAudioFormatAC3, kAudioFormatEnhancedAC3, kAudioFormatMPEGLayer3, kAudioFormatOpus,
                                       kAudioFormatFLAC, kAudioFormatLinearPCM]
            guard ok.contains(CMFormatDescriptionGetMediaSubType(afmt)) else { return nil }
            // audio comes out on the movie timeline; the video index is on the track's own timeline
            let seg = (try? await v.load(.segments))?.first { !$0.isEmpty }
            let shift = seg.map { CMTimeSubtract($0.timeMapping.source.start, $0.timeMapping.target.start) } ?? .zero
            source = AssetAudio(asset: asset, track: a, format: afmt, shift: shift)
        }
        guard let idx = await MediaIndex(asset: asset), ScrubEngine.canDecode(idx) else { return nil }
        return (NativePlayback(index: idx, audio: source), idx)
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
        q.sync { dropSession() }
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
        q.async { [self] in pump(gen) }
    }

    func pause() {
        isPlaying = false
        sync.rate = 0
        endTimer?.invalidate()
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { sync.rate = r }
        q.async { [self] in pump(gen) }
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
        q.sync { gen &+= 1; dropSession() }
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
            inflight = 0
            queued = []
            outstanding = []
            reorder = []
            pumpPending = false
            if sessionBroken { dropSession() }
            let at = Double(targetPTS) / Double(index.timescale) - 0.05
            audioSource?.reset(at: at)
            pump(g)
            if audioSource != nil { audio.requestMediaDataWhenReady(on: q) { [weak self] in self?.feedAudio(g) } }
            if let completion { waitForPicture(g, deadline: CACurrentMediaTime() + 2, completion) }
        }
    }

    private func waitForPicture(_ g: Int, deadline: Double, _ completion: @escaping (Bool) -> Void) {
        guard g == gen else { DispatchQueue.main.async { completion(false) }; return }
        let shown: Bool
        if #available(macOS 14.4, *) {
            // the target itself must have been queued: right after a flush the layer can still hand out the old picture
            shown = flushedGen == g && targetQueuedGen == g && display.sampleBufferRenderer.displayedPixelBuffer() != nil
        }
        else { shown = targetQueuedGen == g && CACurrentMediaTime() > deadline - 1.85 }
        if shown || CACurrentMediaTime() > deadline {
            DispatchQueue.main.async { completion(true) }
            return
        }
        q.asyncAfter(deadline: .now() + 0.004) { [weak self] in self?.waitForPicture(g, deadline: deadline, completion) }
    }

    /// How many pictures to keep decoded ahead: ~0.1 s of video at the current speed, at least 4.
    private var lead: Int { max(4, Int((0.1 * Double(max(rate, 1)) * fps).rounded(.up))) }

    private func dropSession() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        sessionBroken = false
    }

    private func makeSession() -> VTDecompressionSession? {
        let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                     kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: index.format, decoderSpecification: spec,
                                           imageBufferAttributes: attrs, outputCallback: nil,
                                           decompressionSessionOut: &s) == noErr, let s else { return nil }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return s
    }

    /// Keep `lead` pictures decoded ahead of the clock. Frames before an exact-seek target are decoded for
    /// their references only (and skipped entirely when nothing references them).
    private func pump(_ g: Int, timer: Bool = false) {
        if timer { pumpPending = false }
        guard g == gen, !isSuspended else { return }
        if session == nil { session = makeSession() }
        guard let s = session else { return }
        let now = Int64((sync.currentTime().seconds * Double(index.timescale)).rounded(.down))
        queued.removeAll { $0 <= now }
        while vNext < index.samples.count && queued.count + reorder.count + inflight < lead {
            let d = vNext
            let smp = index.samples[d]
            vNext += 1
            if smp.pts < hideBefore && index.isDroppable(d) { continue }
            guard let sb = index.sampleBuffer(d) else { continue }
            inflight += 1
            let fed = smp.pts
            outstanding.append(fed)
            let st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression],
                                                       infoFlagsOut: nil) { [weak self] status, _, image, t, _ in
                self?.q.async { self?.decoded(g, fed, status, image, t) }
            }
            if st != noErr { inflight -= 1; sessionBroken = true; outstanding.removeLast() }
        }
        if vNext >= index.samples.count { VTDecompressionSessionFinishDelayedFrames(s) }
        // playing: come back once about half the queue has been shown
        if sync.rate > 0 && !pumpPending && vNext < index.samples.count {
            pumpPending = true
            let wait = Double(max(1, lead / 2)) / fps / Double(sync.rate)
            q.asyncAfter(deadline: .now() + wait) { [weak self] in self?.pump(g, timer: true) }
        }
    }

    private func decoded(_ g: Int, _ fed: Int64, _ status: OSStatus, _ image: CVImageBuffer?, _ t: CMTime) {
        guard g == gen else { return }
        inflight = max(0, inflight - 1)
        if let i = outstanding.firstIndex(of: fed) { outstanding.remove(at: i) }
        if status != noErr { sessionBroken = true }
        if status == noErr, let image, fed >= hideBefore {
            let at = reorder.firstIndex { $0.pts > fed } ?? reorder.count
            reorder.insert((fed, t, image), at: at)
        }
        // release, in display order, every picture nothing still in the decoder (or about to go in: B-frames
        // follow the frame they show before, within a few frames) can come before
        var floor = outstanding.min() ?? .max
        for d in vNext..<min(vNext + 16, index.samples.count) { floor = min(floor, index.samples[d].pts) }
        while let first = reorder.first, first.pts < floor {
            reorder.removeFirst()
            show(first.image, at: first.time, pts: first.pts, g)
        }
        // every output frees a slot: refill now (frames before a seek target decode back to back,
        // not at the playback pace)
        pump(g)
    }

    private func show(_ image: CVImageBuffer, at t: CMTime, pts p: Int64, _ g: Int) {
        if outFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(outFormat!, imageBuffer: image) {
            var f: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &f)
            outFormat = f
        }
        var t = t
        if let g = grid {
            let k = (Double(p - g.first) / g.step).rounded()
            t = CMTime(seconds: (Double(g.first) + k * g.step) / Double(index.timescale), preferredTimescale: 1_000_000)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded()))),
                                        presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        if let f = outFormat {
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: f,
                                                     sampleTiming: &timing, sampleBufferOut: &sb)
        }
        guard let sb else { return }
        if sync.rate > 0, CMTimeCompare(t, sync.currentTime()) < 0 { Trace.log("late \(p)") }
        if let l = queued.last, p <= l { Trace.log("ooo \(p) after \(l)") }
        display.sampleBufferRenderer.enqueue(sb)
        queued.append(p)
        targetQueuedGen = g
    }

    private func feedAudio(_ g: Int) {
        guard let src = audioSource else { return }
        while g == gen && audio.isReadyForMoreMediaData {
            guard let sb = src.next() else { audio.stopRequestingMediaData(); return }
            if audioTraced != g { audioTraced = g; Trace.log(String(format: "audio first %.3f video target %.3f", CMSampleBufferGetPresentationTimeStamp(sb).seconds, Double(hideBefore) / Double(index.timescale))) }
            audio.enqueue(sb)
        }
    }

    private func startEndWatch() {
        endTimer?.invalidate()
        defer { endTimer?.tolerance = 0.1 }
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            Trace.log(String(format: "native t=%.2f audio=%d err=%@ video=%d vNext=%d", self.currentSeconds,
                             self.audio.status.rawValue, String(describing: self.audio.error), self.display.sampleBufferRenderer.status.rawValue,
                             self.vNext))
            if self.currentSeconds >= self.duration - 0.02 {
                self.pause()
                self.onEnd?()
            }
        }
    }
}
