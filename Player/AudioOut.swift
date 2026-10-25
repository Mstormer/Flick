import AVFoundation

// Audio through AVAudioEngine instead of AVSampleBufferAudioRenderer. The renderer re-primes on every rate
// change and holds the render clock for 40-140 ms (AVPlayer does the same); a time-pitch unit changes rate
// between two render cycles. So: decode here, play through player node → time pitch → output, and let the
// video clock follow what is being heard.

/// An AudioSource's buffers (compressed or PCM) as PCM in one fixed format, starting exactly at the time
/// asked for. Used on one queue only.
final class AudioDecoder {
    let output: AVAudioFormat
    private let source: AudioSource
    private let input: AVAudioFormat
    private let converter: AVAudioConverter
    private var pending: CMSampleBuffer?
    private var next: Double?                       // media time of the next frame out
    private var skip = 0                            // frames still to drop to land on the target
    private var target = 0.0
    private(set) var ended = false

    init?(_ source: AudioSource) {
        let input = AVAudioFormat(cmAudioFormatDescription: source.format)
        let sr = input.sampleRate
        let ch = input.channelCount
        guard sr > 0, ch > 0 else { return nil }
        let out: AVAudioFormat?
        if ch > 2, let layout = input.channelLayout {
            out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, interleaved: false, channelLayout: layout)
        } else {
            out = AVAudioFormat(standardFormatWithSampleRate: sr, channels: ch)
        }
        guard let out, let conv = AVAudioConverter(from: input, to: out) else { return nil }
        conv.primeMethod = .normal                 // no codec latency added: output lines up with its input
        self.source = source
        self.input = input
        output = out
        converter = conv
    }

    func reset(at seconds: Double) {
        converter.reset()
        source.reset(at: max(0, seconds - 0.1))
        pending = nil
        next = nil
        target = seconds
        skip = 0
        ended = false
    }

    /// Up to `frames` of audio from the target on, or nil at the end.
    func read(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        while !ended {
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: frames) else { return nil }
            var error: NSError?
            var fed = false
            let status = converter.convert(to: out, error: &error) { [self] _, outStatus in
                // one source buffer per call keeps the timestamp of what comes out known
                if fed { outStatus.pointee = .noDataNow; return nil }
                guard let sb = pending ?? source.next() else { outStatus.pointee = .endOfStream; return nil }
                pending = nil
                guard let buf = Self.buffer(sb, input) else { outStatus.pointee = .noDataNow; return nil }
                if next == nil {
                    next = CMSampleBufferGetPresentationTimeStamp(sb).seconds - source.codecDelay
                    skip = max(0, Int(((target - next!) * output.sampleRate).rounded()))
                }
                fed = true
                outStatus.pointee = .haveData
                return buf
            }
            if status == .endOfStream || status == .error { ended = true }
            guard out.frameLength > 0 else { if status == .endOfStream || status == .error { return nil }; continue }
            if skip > 0 {
                let drop = min(skip, Int(out.frameLength))
                skip -= drop
                next = next.map { $0 + Double(drop) / output.sampleRate }
                if drop == Int(out.frameLength) { continue }
                Self.dropFront(out, drop)
            }
            next = next.map { $0 + Double(out.frameLength) / output.sampleRate }
            return out
        }
        return nil
    }

    /// Media time just after the last frame handed out.
    var position: Double? { next }

    private static func dropFront(_ b: AVAudioPCMBuffer, _ n: Int) {
        guard let d = b.floatChannelData else { return }
        let left = Int(b.frameLength) - n
        for c in 0..<Int(b.format.channelCount) { memmove(d[c], d[c] + n, left * MemoryLayout<Float>.size) }
        b.frameLength = AVAudioFrameCount(left)
    }

    /// A CMSampleBuffer as the converter's input: PCM copied into a PCM buffer, anything else as packets.
    private static func buffer(_ sb: CMSampleBuffer, _ f: AVAudioFormat) -> AVAudioBuffer? {
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0 else { return nil }
        if f.commonFormat != .otherFormat {
            guard let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n)) else { return nil }
            b.frameLength = AVAudioFrameCount(n)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: b.mutableAudioBufferList) == noErr else { return nil }
            return b
        }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let bytes = CMBlockBufferGetDataLength(block)
        var count = 0
        var descs: UnsafePointer<AudioStreamPacketDescription>?
        CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sb, packetDescriptionsPointerOut: &descs, sizeOut: &count)
        let packets = descs != nil ? count / MemoryLayout<AudioStreamPacketDescription>.size : n
        let b = AVAudioCompressedBuffer(format: f, packetCapacity: AVAudioPacketCount(packets), maximumPacketSize: bytes)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: b.data)
        b.byteLength = UInt32(bytes)
        b.packetCount = AVAudioPacketCount(packets)
        if let descs, let out = b.packetDescriptions { out.update(from: descs, count: packets) }
        else if let out = b.packetDescriptions, packets == 1 { out.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes)) }
        return b
    }
}

/// Plays an AudioDecoder through player node → time pitch → main mixer, keeping about half a second
/// scheduled. Rate, volume and mute change without a gap. Used on its owner's queue, except where noted.
final class AudioOut {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let decoder: AudioDecoder
    private let q: DispatchQueue
    private var gen = 0
    private var start = 0.0                         // media time of node sample 0 since the last reset
    private var paused = false                      // the output dropped what it held; start again from the pictures
    private var scheduled = 0.0                     // seconds scheduled since the last reset
    private var observer: NSObjectProtocol?
    /// Rate, volume and mute (any thread); plus when playing started and each rate change since, in host
    /// seconds, to know how much audio is still on its way to the speakers.
    private let state = Locked((rate: Float(1), volume: Float(1), muted: false, playing: false, since: 0.0, history: [(Double, Double)]()))
    /// Asked for the current video time when the output device changes (the engine restarts there).
    var resumeTime: (() -> Double)?

    init?(source: AudioSource, queue: DispatchQueue) {
        guard let d = AudioDecoder(source) else { return nil }
        decoder = d
        q = queue
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: d.output)
        engine.connect(pitch, to: engine.mainMixerNode, format: d.output)
        engine.prepare()
        guard (try? engine.start()) != nil else { return nil }
        engine.pause()                              // runs only while playing
        // headphones in or out, another output picked: the engine stops; pick up where the picture is
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.q.async {
                guard let self else { return }
                let was = self.state.value.playing
                self.reset(at: self.resumeTime?() ?? self.start)
                if was { self.play() }
            }
        }
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        node.stop()
        engine.stop()
    }

    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// From when audio is pulled to when it's heard: the time-pitch unit's buffer plus the output's.
    var latency: Double { engine.outputNode.presentationLatency + pitch.auAudioUnit.latency }

    /// From any thread.
    var rate: Float {
        get { state.value.rate }
        set {
            var s = state.value
            s.rate = newValue
            s.history.append((Self.now(), Double(newValue)))
            if s.history.count > 16 { s.history.removeFirst(s.history.count - 16) }
            state.value = s
            pitch.rate = newValue
        }
    }
    var volume: Float {
        get { state.value.volume }
        set { state.value.volume = newValue; applyVolume() }
    }
    var isMuted: Bool {
        get { state.value.muted }
        set { state.value.muted = newValue; applyVolume() }
    }
    private func applyVolume() { let s = state.value; engine.mainMixerNode.outputVolume = s.muted ? 0 : s.volume }

    /// Drop everything and get ready to play from `seconds` (media time).
    func reset(at seconds: Double) {
        gen &+= 1
        paused = false
        node.stop()
        decoder.reset(at: seconds)
        start = seconds
        scheduled = 0
        fill(gen)
    }

    func play() {
        if paused { reset(at: resumeTime?() ?? start) }
        if !engine.isRunning { try? engine.start() }
        node.play()
        var s = state.value
        s.playing = true
        s.since = Self.now()
        s.history = [(s.since, Double(s.rate))]
        state.value = s
    }

    func pause() {
        state.value.playing = false
        paused = true
        node.pause()
        engine.pause()
    }

    func stop() {
        gen &+= 1
        state.value.playing = false
        node.stop()
        engine.stop()
    }

    /// Keep about half a second (at the current rate) scheduled.
    private func fill(_ g: Int) {
        guard g == gen else { return }
        let ahead = 0.5 * Double(max(1, rate))
        while scheduled - played < ahead {
            guard let b = decoder.read(4096) else { return }
            scheduled += Double(b.frameLength) / decoder.output.sampleRate
            node.scheduleBuffer(b, completionCallbackType: .dataConsumed) { [weak self] _ in
                self?.q.async { self?.fill(g) }
            }
        }
    }

    /// Seconds of audio the node has handed on since the last reset.
    private var played: Double {
        guard let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return 0 }
        return Double(p.sampleTime) / p.sampleRate
    }

    /// The media time being heard now (any thread): what the node has handed on, less what is still in the
    /// time-pitch unit and the output, which went in at the rates of the last `latency` seconds. Nil until
    /// the first audio reaches the speakers, and after the end.
    var heard: Double? {
        let s = state.value
        let now = Self.now(), l = latency
        guard s.playing, now - s.since > l, let t = node.lastRenderTime, t.isSampleTimeValid,
              let p = node.playerTime(forNodeTime: t), p.sampleTime > 0 else { return nil }
        let pulled = Double(p.sampleTime) / p.sampleRate
        guard pulled < scheduled else { return nil }          // ran out (end of the track)
        // media seconds pulled during the last `l` seconds = the integral of the rate over that window
        var inFlight = 0.0, until = now
        for (h, r) in s.history.reversed() {
            let from = max(h, now - l)
            if until > from { inFlight += (until - from) * r }
            until = min(until, h)
            if h <= now - l { break }
        }
        return start + pulled - inFlight
    }
}

/// AudioOut for a player whose pictures run on a render synchronizer: audio calls go through their own
/// queue in the order made, and the picture clock starts and changes speed when the sound does (the
/// output is up to a quarter second behind), then `steer` keeps it there.
final class SyncedAudio {
    private let out: AudioOut
    private let aq = DispatchQueue(label: "flick.audio", qos: .userInitiated)
    private let sync: AVSampleBufferRenderSynchronizer
    private let calm = Locked(0.0)                  // host time before which steering waits (just started/changed)

    init?(source: AudioSource, sync: AVSampleBufferRenderSynchronizer) {
        guard let o = AudioOut(source: source, queue: aq) else { return nil }
        out = o
        self.sync = sync
        o.resumeTime = { sync.currentTime().seconds }
    }

    func reset(at seconds: Double) { aq.async { [out] in out.reset(at: seconds) } }
    func pause() { pending.bump(); aq.async { [out] in out.pause() } }
    func stop() { aq.sync { out.stop() } }
    var volume: Float { get { out.volume } set { out.volume = newValue } }
    var isMuted: Bool { get { out.isMuted } set { out.isMuted = newValue } }

    private let clockQ = DispatchQueue(label: "flick.audio.clock", qos: .userInteractive)
    private let pending = Latest()                  // newest scheduled picture-clock change

    /// Start the sound now and the pictures when it is heard (call where any reset is already queued).
    func play(rate r: Float) {
        out.rate = r
        aq.async { [out] in out.play() }
        later(out.latency) { [sync] in sync.setRate(r, time: sync.currentTime()) }
    }

    /// New speed: the time-pitch unit takes it at once; the pictures change when that audio is heard,
    /// so they never run ahead of or behind the sound.
    func setRate(_ r: Float, playing: Bool) {
        out.rate = r
        guard playing else { return }
        later(out.latency) { [sync] in sync.setRate(r, time: sync.currentTime()) }
    }

    /// Paused or seeking: forget picture-clock changes still waiting.
    func cancelClock() { pending.bump() }

    private func later(_ delay: Double, _ change: @escaping () -> Void) {
        let g = pending.bump()
        calm.value = AudioOut.now() + delay + 0.5
        clockQ.asyncAfter(deadline: .now() + delay) { [pending] in if g == pending.value { change() } }
    }

    /// Every half second while playing: nudge the picture clock (at most 1%) toward the audio being heard;
    /// move it outright only when far apart (an output change).
    func steer(rate r: Float) {
        guard r > 0, AudioOut.now() > calm.value, sync.rate > 0, let heard = out.heard else { return }
        let drift = heard - sync.currentTime().seconds
        if abs(drift) > 0.25 {
            sync.setRate(r, time: CMTime(seconds: heard, preferredTimescale: 1_000_000_000))
        } else {
            sync.rate = r * Float(1 + max(-0.01, min(0.01, drift * 2)))
        }
    }
}
