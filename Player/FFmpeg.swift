import AVFoundation
import Accelerate
import CFFmpeg
import VideoToolbox

// Formats macOS can't open or decode (AVI, VOB, MPEG-TS, Ogg/Opus, FLV, RealMedia, WMV/VC-1, WMA, DTS,
// TrueHD, Vorbis, VP9 the hardware decoder refuses, damaged MP4s AVFoundation turns down…), through the
// bundled LGPL FFmpeg libraries (Tools/build-ffmpeg.sh). Everything here decodes in software, so it only
// runs for files nothing else can play.

/// A value shared between the feed queue and the main thread.
final class Locked<T> {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

/// An Int several threads read and one writes: lets a running decode notice a newer seek and stop.
final class Latest {
    private let lock = NSLock()
    private var v = 0
    var value: Int { lock.withLock { v } }
    @discardableResult func bump() -> Int { lock.withLock { v &+= 1; return v } }
}

// MARK: - Shared

/// A timestamp in seconds, or nil where the file left it unset.
func ffSeconds(_ ts: Int64, _ tb: AVRational) -> Double? { ts != ff_nopts() ? Double(ts) * av_q2d(tb) : nil }

/// An opened decoder with its packet and frame, freed together (a failed init runs no deinit, so nothing is
/// allocated before it is known to open), and the receive/send loop both decoders share. One queue only.
final class FFDecoder {
    let ctx: UnsafeMutablePointer<AVCodecContext>
    let pkt: UnsafeMutablePointer<AVPacket>
    let frame: UnsafeMutablePointer<AVFrame>
    private var drained = false                     // the flush packet is in: what is left comes out, then the end
    private var errors = 0                          // decode errors in a row
    /// The decoder has put out its last frame (or gave nothing but errors for a long stretch).
    private(set) var atEnd = false

    init?(_ codec: UnsafePointer<AVCodec>, timeBase: AVRational, _ configure: (UnsafeMutablePointer<AVCodecContext>) -> Void) {
        var c = avcodec_alloc_context3(codec), p = av_packet_alloc(), f = av_frame_alloc()
        if let c { configure(c); c.pointee.pkt_timebase = timeBase }
        guard let c0 = c, let p0 = p, let f0 = f, avcodec_open2(c0, codec, nil) >= 0 else {
            avcodec_free_context(&c); av_packet_free(&p); av_frame_free(&f); return nil
        }
        ctx = c0; pkt = p0; frame = f0
    }

    deinit {
        var c: UnsafeMutablePointer<AVCodecContext>? = ctx, p: UnsafeMutablePointer<AVPacket>? = pkt, f: UnsafeMutablePointer<AVFrame>? = frame
        avcodec_free_context(&c); av_packet_free(&p); av_frame_free(&f)
    }

    func flush() { avcodec_flush_buffers(ctx); drained = false; errors = 0; atEnd = false }

    /// Decodes until a frame is in `frame` (true; the caller unrefs it) or there are no more (false): the end,
    /// a long run of errors, or `abort`.
    func receive(_ read: (UnsafeMutablePointer<AVPacket>) -> Bool, abort: () -> Bool = { false }) -> Bool {
        while !abort() {
            let r = avcodec_receive_frame(ctx, frame)
            if r >= 0 { errors = 0; return true }
            if r == ff_eof() { atEnd = true; return false }
            if r != ff_eagain() {
                // a damaged packet: threaded decoding reports it here, frames later. Carry on like any player;
                // only a long run of nothing else (a file of garbage) is taken as the end
                errors += 1
                if errors > 250 { atEnd = true; return false }
                continue
            }
            if drained { atEnd = true; return false }
            if read(pkt) {
                avcodec_send_packet(ctx, pkt)        // a damaged packet is skipped, like any player would
                av_packet_unref(pkt)
            } else {
                avcodec_send_packet(ctx, nil)
                drained = true
            }
        }
        return false
    }
}

extension Playback {
    /// The half-second watch a backend on a render synchronizer runs while playing (main thread): stop and
    /// report once `currentSeconds` reaches `end`, then `steer` (keep the picture clock on the sound).
    /// Invalidates `old`; the caller keeps the returned timer and invalidates it on pause.
    func endWatch(replacing old: Timer?, end: @escaping (Self) -> Double, steer: @escaping (Self) -> Void) -> Timer {
        old?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            if self.currentSeconds >= end(self) - 0.02 {
                self.pause()
                self.onEnd?()
            }
            steer(self)
        }
        t.tolerance = 0.1
        return t
    }
}

// MARK: - Audio

/// Compressed audio packets for FFAudio, from the Matroska table or from libavformat.
protocol PacketFeed: AnyObject {
    var timeBase: AVRational { get }
    func reset(at seconds: Double)
    /// Fills `pkt` with the next packet; false at the end.
    func next(_ pkt: UnsafeMutablePointer<AVPacket>) -> Bool
}

/// Decoded to interleaved Float32 for AudioOut. Used on one queue only.
final class FFAudio: AudioSource {
    let format: CMAudioFormatDescription
    private let dec: FFDecoder
    private let feed: PacketFeed
    private let channels: Int
    private let rate: Int32
    private var layout: AVChannelLayout             // the output's speakers (the first frame's), for frames that differ
    private var nextTime = 0.0
    private var skipBefore = -Double.infinity      // after a reset: audio before the target is dropped, not played early
    /// Where the decoded sound stopped, once the decoder has put out its last frame (truncated files end
    /// before their stated length).
    let soundEnd = Locked(Double.infinity)

    convenience init?(codec id: AVCodecID, extradata: Data?, sampleRate: Int, channels ch: Int, feed: PacketFeed) {
        guard let codec = avcodec_find_decoder(id) else { return nil }
        self.init(codec: codec, feed: feed) { c in
            c.pointee.sample_rate = Int32(clamping: sampleRate)
            av_channel_layout_default(&c.pointee.ch_layout, Int32(clamping: ch))
            if let e = extradata, !e.isEmpty, let p = av_mallocz(e.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)) {
                e.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: e.count)
                c.pointee.extradata = p.assumingMemoryBound(to: UInt8.self)
                c.pointee.extradata_size = Int32(e.count)
            }
        }
    }

    convenience init?(parameters par: UnsafePointer<AVCodecParameters>, feed: PacketFeed) {
        guard let codec = avcodec_find_decoder(par.pointee.codec_id) else { return nil }
        self.init(codec: codec, feed: feed) { avcodec_parameters_to_context($0, par) }
    }

    private init?(codec: UnsafePointer<AVCodec>, feed: PacketFeed, _ configure: (UnsafeMutablePointer<AVCodecContext>) -> Void) {
        guard let d = FFDecoder(codec, timeBase: feed.timeBase, { configure($0); $0.pointee.request_sample_fmt = AV_SAMPLE_FMT_FLTP })
        else { return nil }
        // the real channel layout and rate are only known once a frame is out
        feed.reset(at: 0)
        var l = AVChannelLayout(), r: Int32 = 0, tries = 0
        while r == 0 && tries < 64 && feed.next(d.pkt) {
            tries += 1
            if avcodec_send_packet(d.ctx, d.pkt) >= 0, avcodec_receive_frame(d.ctx, d.frame) >= 0,
               d.frame.pointee.sample_rate > 0, d.frame.pointee.ch_layout.nb_channels > 0,
               av_channel_layout_copy(&l, &d.frame.pointee.ch_layout) >= 0 {
                r = d.frame.pointee.sample_rate
            }
            av_packet_unref(d.pkt)
            av_frame_unref(d.frame)
        }
        guard r > 0, let f = Self.format(l, r) else { av_channel_layout_uninit(&l); return nil }
        d.flush()
        dec = d
        self.feed = feed
        channels = Int(l.nb_channels)
        rate = r
        layout = l
        format = f
    }

    deinit { av_channel_layout_uninit(&layout) }

    private static func format(_ l: AVChannelLayout, _ rate: Int32) -> CMAudioFormatDescription? {
        let ch = Int(l.nb_channels), mask = l.order == AV_CHANNEL_ORDER_NATIVE ? l.u.mask : 0
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * ch), mFramesPerPacket: 1,
                                               mBytesPerFrame: UInt32(4 * ch), mChannelsPerFrame: UInt32(ch),
                                               mBitsPerChannel: 32, mReserved: 0)
        // FFmpeg's channel mask uses the same bits, in the same sample order, as Core Audio's channel bitmap
        var layout = AudioChannelLayout()
        if ch == 1 { layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono }
        else if ch == 2 { layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo }
        else if mask != 0, mask <= UInt64(UInt32.max), mask.nonzeroBitCount == ch {
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
            layout.mChannelBitmap = AudioChannelBitmap(rawValue: UInt32(mask))
        } else { layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(ch) }
        var f: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &f) == noErr
        else { return nil }
        return f
    }

    func reset(at seconds: Double) {
        dec.flush()
        feed.reset(at: seconds)
        nextTime = seconds
        skipBefore = seconds
        soundEnd.value = .infinity
    }

    func next() -> CMSampleBuffer? {
        while dec.receive({ feed.next($0) }) {
            defer { av_frame_unref(dec.frame) }
            if let sb = buffer() { return sb }
        }
        if dec.atEnd { soundEnd.value = nextTime }
        return nil
    }

    private func buffer() -> CMSampleBuffer? {
        let fr = dec.frame
        let n0 = Int(fr.pointee.nb_samples), fch = Int(fr.pointee.ch_layout.nb_channels), frameRate = Int(fr.pointee.sample_rate)
        guard n0 > 0, fch > 0, frameRate > 0 else { return nil }
        // a stream can change speakers or rate partway (broadcast recordings switch between 5.1 and stereo):
        // other speakers are mapped onto the output's; another rate has no resampler here, so it plays as
        // silence of the same length, which keeps the clock and the rest of the sound going
        let sameRate = frameRate == Int(rate)
        let total = sameRate ? n0 : Int((Double(n0) * Double(rate) / Double(frameRate)).rounded())
        guard total > 0 else { return nil }
        var t = ffSeconds(fr.pointee.best_effort_timestamp, feed.timeBase) ?? nextTime
        nextTime = t + Double(total) / Double(rate)
        // the demuxer can only land on a packet boundary (or, without an audio index, well before): trim to the target
        var from = 0
        if t < skipBefore {
            guard nextTime > skipBefore else { return nil }
            from = min(total - 1, Int(((skipBefore - t) * Double(rate)).rounded(.down)))
            t += Double(from) / Double(rate)
        }
        skipBefore = -Double.infinity
        let n = total - from
        let bytes = n * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var raw: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &raw)
        guard let raw else { return nil }
        let out = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: Float.self)
        if !sameRate { memset(out, 0, bytes) }
        else if fch == channels && av_channel_layout_compare(&layout, &fr.pointee.ch_layout) == 0 {
            Self.interleave(fr, n0, channels, from: from, into: out)
        } else {
            let tmp = UnsafeMutablePointer<Float>.allocate(capacity: n * fch)
            defer { tmp.deallocate() }
            Self.interleave(fr, n0, fch, from: from, into: tmp)
            remix(tmp, n, fch, into: out)
        }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: n,
                                                             presentationTimeStamp: CMTime(seconds: t, preferredTimescale: rate),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    /// A frame whose speakers differ from the output's: each output speaker from the same one in the frame
    /// (by position where either side has no names), the centre folded into front left and right when the
    /// output has none (that is where the dialogue is), everything averaged into a mono output.
    private func remix(_ src: UnsafePointer<Float>, _ n: Int, _ fch: Int, into out: UnsafeMutablePointer<Float>) {
        var fl = dec.frame.pointee.ch_layout
        let named = fl.order != AV_CHANNEL_ORDER_UNSPEC && layout.order != AV_CHANNEL_ORDER_UNSPEC
        let speakers = (0..<channels).map { av_channel_layout_channel_from_index(&layout, UInt32($0)) }
        let map = (0..<channels).map { c in named ? Int(av_channel_layout_index_from_channel(&fl, speakers[c])) : (c < fch ? c : -1) }
        let centre = named && !speakers.contains(AV_CHAN_FRONT_CENTER) ? Int(av_channel_layout_index_from_channel(&fl, AV_CHAN_FRONT_CENTER)) : -1
        let front = speakers.map { $0 == AV_CHAN_FRONT_LEFT || $0 == AV_CHAN_FRONT_RIGHT }
        for i in 0..<n {
            let s = src + i * fch, d = out + i * channels
            if channels == 1 {
                var sum: Float = 0
                for k in 0..<fch { sum += s[k] }
                d[0] = sum / Float(fch)
                continue
            }
            for c in 0..<channels {
                var v: Float = map[c] >= 0 ? s[map[c]] : 0
                if centre >= 0 && front[c] { v += 0.7071 * s[centre] }
                d[c] = v
            }
        }
    }

    /// Any of the sample formats these decoders put out, as interleaved Float32.
    private static func interleave(_ f: UnsafeMutablePointer<AVFrame>, _ total: Int, _ ch: Int, from: Int, into out: UnsafeMutablePointer<Float>) {
        let n = total - from
        let fmt = AVSampleFormat(rawValue: f.pointee.format)
        let planar = av_sample_fmt_is_planar(fmt) != 0
        let bytesPer = Int(av_get_bytes_per_sample(fmt))
        for c in 0..<(planar ? ch : 1) {
            let src = UnsafeMutableRawPointer((f.pointee.extended_data[planar ? c : 0])!) + from * bytesPer * (planar ? 1 : ch)
            let count = planar ? n : n * ch
            let stride = planar ? ch : 1
            let dst = out + (planar ? c : 0)
            func put<T>(_: T.Type, _ conv: (T) -> Float) {
                let s = src.assumingMemoryBound(to: T.self)
                for i in 0..<count { dst[i * stride] = conv(s[i]) }
            }
            switch fmt {
            case AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_FLT: put(Float.self) { $0 }
            case AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_S16: put(Int16.self) { Float($0) / 32768 }
            case AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_S32: put(Int32.self) { Float($0) / 2_147_483_648 }
            case AV_SAMPLE_FMT_U8P, AV_SAMPLE_FMT_U8: put(UInt8.self) { (Float($0) - 128) / 128 }
            case AV_SAMPLE_FMT_S64P, AV_SAMPLE_FMT_S64: put(Int64.self) { Float(Double($0) / 9_223_372_036_854_775_808) }
            case AV_SAMPLE_FMT_DBLP, AV_SAMPLE_FMT_DBL: put(Double.self) { Float($0) }
            default: for i in 0..<count { dst[i * stride] = 0 }
            }
        }
    }
}

/// Matroska audio packets (already split from their laces) for FFAudio.
final class MKVPacketFeed: PacketFeed {
    private let mkv: MKVFile
    private let packets: MKVFile.Packets
    let timeBase: AVRational
    private var nextIndex = 0

    init(_ mkv: MKVFile, track: MKVFile.Track) {
        self.mkv = mkv
        packets = mkv.packets[track.number] ?? .init()
        // exactly timecodeScale / 1e9 s (a scale that doesn't divide 1e9 would drift; one above it, divide by zero)
        var n: Int32 = 0, d: Int32 = 0
        av_reduce(&n, &d, max(1, mkv.timecodeScale), 1_000_000_000, Int64(Int32.max))
        timeBase = AVRational(num: max(1, n), den: max(1, d))
    }

    func reset(at seconds: Double) {
        // the packet playing at `seconds`; FFAudio trims it to the exact sample
        let t = Int64(seconds / av_q2d(timeBase))
        nextIndex = max(0, (packets.firstIndex { $0.pts > t } ?? packets.count) - 1)
    }

    func next(_ pkt: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard nextIndex < packets.count else { return false }
        let p = packets[nextIndex]
        nextIndex += 1
        guard av_new_packet(pkt, p.size) >= 0 else { return false }
        memcpy(pkt.pointee.data, mkv.base + Int(p.offset), Int(p.size))
        pkt.pointee.pts = p.pts
        pkt.pointee.dts = p.pts
        return true
    }
}

extension MKVCodecs {
    /// Matroska audio only FFmpeg decodes here.
    static func ffAudioCodec(_ t: MKVFile.Track) -> AVCodecID? {
        switch t.codecID {
        case let id where id.hasPrefix("A_DTS"): return AV_CODEC_ID_DTS
        case "A_TRUEHD": return AV_CODEC_ID_TRUEHD
        case "A_MLP": return AV_CODEC_ID_MLP
        case "A_VORBIS": return AV_CODEC_ID_VORBIS
        case "A_ALAC": return AV_CODEC_ID_ALAC
        default: return nil
        }
    }

    /// Video the native player can take (hardware or VideoToolbox decoders); anything else goes to FFmpeg.
    static func mayPlayNatively(_ t: MKVFile.Track) -> Bool {
        ["V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC", "V_AV1", "V_VP9"].contains(t.codecID)
    }

    /// FFmpeg can read this file as it plays, with no packet table: every audio track has an FFmpeg decoder
    /// here and there are no Matroska subtitles (those are read from the table).
    static func ffmpegReadsAll(_ mkv: MKVFile) -> Bool {
        !mkv.tracks.contains { $0.type == 17 }
            && mkv.audioTracks.allSatisfy { $0.codecID.hasPrefix("A_PCM") || ffAudioCodec($0) != nil }
    }

    /// The audio to play from a Matroska file: the default track if anything here decodes it, else the
    /// first track that decodes. The system's decoders first, FFmpeg's for the rest.
    static func audioSource(_ mkv: MKVFile) -> AudioSource? {
        let tracks = mkv.audioTracks
        func make(_ t: MKVFile.Track) -> AudioSource? {
            if audioFormat(t) != nil { return MKVAudio(mkv, track: t) }
            guard let id = ffAudioCodec(t) else { return nil }
            var extra = t.codecPrivate
            // Matroska keeps ALAC's bare 24-byte config; FFmpeg wants it inside its 'alac' atom
            if id == AV_CODEC_ID_ALAC, let c = extra, c.count == 24 { extra = Data([0, 0, 0, 36]) + Data("alac".utf8) + Data(count: 4) + c }
            return FFAudio(codec: id, extradata: extra, sampleRate: Int(t.sampleRate), channels: t.channels,
                           feed: MKVPacketFeed(mkv, track: t))
        }
        for t in tracks.filter(\.isDefault) + tracks { if let s = make(t) { return s } }
        return nil
    }
}

// MARK: - Demuxing

/// One stream of a file through libavformat; every other stream is skipped at the demuxer.
final class FFDemux: PacketFeed {
    let ctx: UnsafeMutablePointer<AVFormatContext>
    let stream: Int32
    let timeBase: AVRational

    init?(url: URL, type: CFFmpeg.AVMediaType) {
        var c: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&c, url.path, nil, nil) >= 0, let c0 = c else { return nil }
        // damaged files: the probe can fail on a broken stretch and still have found the streams
        guard avformat_find_stream_info(c0, nil) >= 0 || c0.pointee.nb_streams > 0 else { avformat_close_input(&c); return nil }
        // the best stream something here decodes (a file's first audio can be in a format with no decoder), and
        // never cover art: libavformat offers it as video, and an Ogg or APE file with a cover would play as one
        // picture that ends at once
        var s = av_find_best_stream(c0, type, -1, -1, nil, 0)
        if s >= 0, avcodec_find_decoder(c0.pointee.streams[Int(s)]!.pointee.codecpar.pointee.codec_id) == nil
            || c0.pointee.streams[Int(s)]!.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
            s = Int32((0..<Int(c0.pointee.nb_streams)).first { i in
                let p = c0.pointee.streams[i]!.pointee.codecpar.pointee
                return p.codec_type == type && avcodec_find_decoder(p.codec_id) != nil
                    && c0.pointee.streams[i]!.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0
            } ?? -1)
        }
        guard s >= 0 else { avformat_close_input(&c); return nil }
        for i in 0..<Int(c0.pointee.nb_streams) where i != Int(s) { c0.pointee.streams[i]!.pointee.discard = AVDISCARD_ALL }
        ctx = c0
        stream = s
        timeBase = c0.pointee.streams[Int(s)]!.pointee.time_base
    }

    deinit { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c) }

    var parameters: UnsafeMutablePointer<AVCodecParameters> { ctx.pointee.streams[Int(stream)]!.pointee.codecpar }
    var avStream: UnsafeMutablePointer<AVStream> { ctx.pointee.streams[Int(stream)]! }

    /// File duration in seconds.
    var duration: Double {
        let s = avStream.pointee
        if s.duration > 0 { return Double(s.duration) * av_q2d(s.time_base) }
        return ctx.pointee.duration > 0 ? Double(ctx.pointee.duration) / Double(AV_TIME_BASE) : 0
    }

    var startSeconds: Double {
        let s = avStream.pointee
        return ffSeconds(s.start_time, s.time_base) ?? 0
    }

    /// To the keyframe at or before `seconds` (stream time). Containers without an index (MPEG program and
    /// transport streams, damaged AVI…) seek by guessing from bytes and timestamps and can land well after the
    /// target (seconds late, which would hold the picture until the clock caught up): where it landed is
    /// checked, and it steps back until it is at or before the target, or goes to the start of the file.
    func reset(at seconds: Double) {
        let begin = startSeconds
        var aim = seconds
        for _ in 0..<6 {
            seek(aim)
            guard let landed = firstTime() else { seek(aim); return }      // nothing after it: as good as it gets
            if landed <= seconds + 0.1 { seek(aim); return }
            if aim <= begin { break }
            aim = max(begin, aim - max(1, 2 * (landed - seconds)))
        }
        // still late: from the very beginning (the decoder skips forward to the target)
        if av_seek_frame(ctx, -1, 0, AVSEEK_FLAG_BYTE) < 0 { seek(begin) }
    }

    private func seek(_ seconds: Double) {
        let ts = Int64((seconds / av_q2d(timeBase)).rounded(.down))
        if avStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
            // audio rarely has its own index (ASF has none): seek by the container's default stream instead
            let us = Int64(seconds * Double(AV_TIME_BASE))
            if av_seek_frame(ctx, -1, us, AVSEEK_FLAG_BACKWARD) >= 0 { return }
        }
        if av_seek_frame(ctx, stream, ts, AVSEEK_FLAG_BACKWARD) < 0 { av_seek_frame(ctx, stream, ts, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY) }
    }

    /// The time of the first keyframe of this stream from here: where decoding can really start (a seek can
    /// land mid-GOP, and everything before the next keyframe is undecodable). Reads ahead; seek again after.
    private func firstTime() -> Double? {
        guard let pkt = av_packet_alloc() else { return nil }
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        defer { av_packet_free(&p) }
        for _ in 0..<3000 {
            guard next(pkt) else { return nil }
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.flags & AV_PKT_FLAG_KEY != 0 else { continue }
            if let t = ffSeconds(pkt.pointee.pts, timeBase) ?? ffSeconds(pkt.pointee.dts, timeBase) { return t }
        }
        return nil
    }

    func next(_ pkt: UnsafeMutablePointer<AVPacket>) -> Bool {
        var errors = 0
        while true {
            let r = av_read_frame(ctx, pkt)
            if r >= 0 {
                if pkt.pointee.stream_index == stream { return true }
                av_packet_unref(pkt)
                continue
            }
            // a damaged stretch: the demuxer resyncs on the next good data; only the end (or a dead file) stops
            if r == ff_eof() || ctx.pointee.pb?.pointee.eof_reached != 0 { return false }
            errors += 1
            if errors > 1000 { return false }
        }
    }
}

/// Decodes one video stream to IOSurface-backed NV12 (or P010) pixel buffers.
final class FFVideo {
    let demux: FFDemux
    private let dec: FFDecoder
    private var ctx: UnsafeMutablePointer<AVCodecContext> { dec.ctx }
    private var frame: UnsafeMutablePointer<AVFrame> { dec.frame }
    private var pool: CVPixelBufferPool?
    private var poolKey = (0, 0, OSType(0))
    private var lastPts = -Double.infinity
    private var unshowable = 0
    private var sws: UnsafeMutablePointer<SwsContext>?               // other pixel formats (DV's 4:1:1, RGB, palette, 12-bit…) to 4:2:0
    private var converted: UnsafeMutablePointer<AVFrame>?            // swscale's output, made on first use
    let width: Int, height: Int
    let displaySize: CGSize
    let frameDuration: Double

    init?(url: URL, threads: Bool = true) {
        guard let d = FFDemux(url: url, type: AVMEDIA_TYPE_VIDEO) else { return nil }
        let par = d.parameters
        guard par.pointee.width > 0, par.pointee.height > 0, let codec = avcodec_find_decoder(par.pointee.codec_id),
              let dc = FFDecoder(codec, timeBase: d.timeBase, { c in
                  avcodec_parameters_to_context(c, par)
                  c.pointee.thread_count = threads ? 0 : 1
                  c.pointee.thread_type = threads ? FF_THREAD_FRAME | FF_THREAD_SLICE : FF_THREAD_SLICE
              }) else { return nil }
        demux = d
        dec = dc
        width = Int(par.pointee.width); height = Int(par.pointee.height)
        let sar = av_guess_sample_aspect_ratio(d.ctx, d.avStream, nil)
        let aspect = sar.num > 0 && sar.den > 0 ? av_q2d(sar) : 1
        displaySize = CGSize(width: (Double(width) * aspect).rounded(), height: Double(height))
        // a guessed rate can be absurd (1000 fps from a millisecond time base, or a frame a minute): it sets how
        // many pictures are decoded ahead and how often, so it is kept to what film and video use
        let fr = av_guess_frame_rate(d.ctx, d.avStream, nil)
        frameDuration = fr.num > 0 && fr.den > 0 ? min(1, max(1.0 / 240, 1 / av_q2d(fr))) : 1.0 / 30
    }

    deinit {
        av_frame_free(&converted)
        sws_freeContext(sws)
    }

    static let eightBit = [AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUV444P, AV_PIX_FMT_YUVJ444P]

    /// Whether this file's pictures can be shown: any software pixel format (others go through swscale).
    var supported: Bool {
        let f = AVPixelFormat(rawValue: ctx.pointee.pix_fmt.rawValue)
        guard f != AV_PIX_FMT_NONE else { return true }       // known once the first frame is out
        guard let d = av_pix_fmt_desc_get(f) else { return false }
        return d.pointee.flags & UInt64(AV_PIX_FMT_FLAG_HWACCEL) == 0
    }

    func seek(to seconds: Double) {
        dec.flush()
        demux.reset(at: seconds)
        lastPts = -Double.infinity
        unshowable = 0
    }

    /// The next picture in display order, or nil at the end (or when `abort` says a newer request came in).
    /// Frames `skip` turns down are decoded for their references but never converted.
    func next(skip: (Double, Double) -> Bool = { _, _ in false }, abort: () -> Bool = { false }) -> (CVPixelBuffer, pts: Double, dur: Double)? {
        while dec.receive({ demux.next($0) }, abort: abort) {
            defer { av_frame_unref(frame) }
            let f = frame.pointee
            let dur = f.duration > 0 ? Double(f.duration) * av_q2d(demux.timeBase) : frameDuration
            // damaged or oddly muxed files: a picture without a time follows the one before it
            guard let pts = ffSeconds(f.best_effort_timestamp, demux.timeBase) ?? (lastPts.isFinite ? lastPts + frameDuration : nil)
            else { continue }
            lastPts = pts
            if skip(pts, dur) { continue }
            // a picture that can't be converted is skipped; a stream of them means nothing here shows it
            guard let px = pixelBuffer() else { unshowable += 1; if unshowable > 120 { return nil }; continue }
            unshowable = 0
            return (px, pts, dur)
        }
        return nil
    }

    /// The frame as one of the layouts below: unusual pixel formats are converted to planar 4:2:0 first,
    /// keeping its colour tags and field order.
    private func normalized() -> AVFrame? {
        let f = frame.pointee
        let fmt = AVPixelFormat(rawValue: f.format)
        if fmt == AV_PIX_FMT_YUV420P10LE || Self.eightBit.contains(fmt) { return f }
        guard f.width > 0, f.height > 0, let desc = av_pix_fmt_desc_get(fmt) else { return nil }
        let deep = Int(desc.pointee.comp.0.depth) > 8
        let to = deep ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P
        sws = sws_getCachedContext(sws, f.width, f.height, fmt, f.width, f.height, to, Int32(SWS_BICUBIC.rawValue), nil, nil, nil)
        if converted == nil { converted = av_frame_alloc() }
        guard let sws, let c = converted else { return nil }
        if c.pointee.width != f.width || c.pointee.height != f.height || c.pointee.format != to.rawValue {
            av_frame_unref(c)
            c.pointee.width = f.width; c.pointee.height = f.height; c.pointee.format = to.rawValue
            guard av_frame_get_buffer(c, 0) >= 0 else { return nil }
        }
        guard av_frame_make_writable(c) >= 0 else { return nil }
        let o = c.pointee
        let src: [UnsafePointer<UInt8>?] = [f.data.0, f.data.1, f.data.2, f.data.3].map { $0.map { UnsafePointer($0) } }
        let srcStride = [f.linesize.0, f.linesize.1, f.linesize.2, f.linesize.3]
        let dst: [UnsafeMutablePointer<UInt8>?] = [o.data.0, o.data.1, o.data.2, o.data.3]
        let dstStride = [o.linesize.0, o.linesize.1, o.linesize.2, o.linesize.3]
        guard sws_scale(sws, src, srcStride, 0, f.height, dst, dstStride) > 0 else { return nil }
        var out = c.pointee
        out.flags = f.flags
        out.color_range = desc.pointee.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0 ? AVCOL_RANGE_MPEG : f.color_range
        out.colorspace = desc.pointee.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0 ? AVCOL_SPC_SMPTE170M : f.colorspace   // swscale's RGB matrix
        out.color_primaries = f.color_primaries
        out.color_trc = f.color_trc
        return out
    }

    private func pixelBuffer() -> CVPixelBuffer? {
        guard let f = normalized() else { return nil }
        let w = Int(f.width), h = Int(f.height)
        let fmt = AVPixelFormat(rawValue: f.format)
        let ten = fmt == AV_PIX_FMT_YUV420P10LE
        guard ten || Self.eightBit.contains(fmt), w > 0, h > 0, let desc = av_pix_fmt_desc_get(fmt) else { return nil }
        let full = [AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P].contains(fmt) || f.color_range == AVCOL_RANGE_JPEG
        let type = ten ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                       : (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        if pool == nil || poolKey != (w, h, type) {
            let attrs = [kCVPixelBufferPixelFormatTypeKey: type, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                         kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                         kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
            pool = nil                                  // a failed create must not leave the old size's pool
            CVPixelBufferPoolCreate(nil, nil, attrs, &pool)
            poolKey = (w, h, type)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let px = out else { return nil }
        CVPixelBufferLockBaseAddress(px, [])
        defer { CVPixelBufferUnlockBaseAddress(px, []) }
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!, yStride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let uv = CVPixelBufferGetBaseAddressOfPlane(px, 1)!, uvStride = CVPixelBufferGetBytesPerRowOfPlane(px, 1)
        let src = (f.data.0!, f.data.1!, f.data.2!)
        let ls = (Int(f.linesize.0), Int(f.linesize.1), Int(f.linesize.2))
        if !ten {
            // interlaced (VC-1 broadcast, DVD-sourced WMV): a [1 2 1] vertical blend hides the combing
            let interlaced = f.flags & AV_FRAME_FLAG_INTERLACED != 0
            func plane(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ pw: Int, _ ph: Int) -> vImage_Buffer {
                vImage_Buffer(data: p, height: vImagePixelCount(ph), width: vImagePixelCount(pw), rowBytes: stride)
            }
            func blend(_ from: inout vImage_Buffer, _ to: inout vImage_Buffer) {
                let kernel: [Int16] = [1, 2, 1]
                vImageConvolve_Planar8(&from, &to, nil, 0, 0, kernel, 3, 1, 4, 0, vImage_Flags(kvImageEdgeExtend))
            }
            var yIn = plane(src.0, ls.0, w, h), yOut = plane(y.assumingMemoryBound(to: UInt8.self), yStride, w, h)
            if interlaced { blend(&yIn, &yOut) } else { for r in 0..<h { memcpy(y + r * yStride, src.0 + r * ls.0, w) } }
            // chroma at 4:2:0 size: 4:2:2 and 4:4:4 are averaged down
            let sx = Int(desc.pointee.log2_chroma_w), sy = Int(desc.pointee.log2_chroma_h)
            var temps: [UnsafeMutablePointer<UInt8>] = []
            defer { temps.forEach { $0.deallocate() } }
            func chroma(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int) -> vImage_Buffer {
                var b: vImage_Buffer
                if sx == 1 && sy == 1 { b = plane(p, stride, cw, ch) }
                else {
                    let t = UnsafeMutablePointer<UInt8>.allocate(capacity: cw * ch); temps.append(t)
                    let fw = sx == 1 ? 1 : 2, fh = sy == 1 ? 1 : 2
                    let pw = (w + (1 << sx) - 1) >> sx, ph = (h + (1 << sy) - 1) >> sy
                    for r in 0..<ch { for c in 0..<cw {
                        var sum = 0, n = 0
                        for dy in 0..<fh { for dx in 0..<fw {
                            let rr = min(ph - 1, r * fh + dy), cc = min(pw - 1, c * fw + dx)
                            sum += Int(p[rr * stride + cc]); n += 1
                        } }
                        t[r * cw + c] = UInt8((sum + n / 2) / n)
                    } }
                    b = plane(t, cw, cw, ch)
                }
                guard interlaced else { return b }
                let t = UnsafeMutablePointer<UInt8>.allocate(capacity: cw * ch); temps.append(t)
                var o = plane(t, cw, cw, ch)
                blend(&b, &o)
                return o
            }
            var u = chroma(src.1, ls.1), v = chroma(src.2, ls.2)
            withUnsafePointer(to: &u) { up in withUnsafePointer(to: &v) { vp in
                var planes: [UnsafePointer<vImage_Buffer>?] = [up, vp]
                var dest: [UnsafeMutableRawPointer?] = [uv, uv + 1]
                vImageConvert_PlanarToChunky8(&planes, &dest, 2, 2, vImagePixelCount(cw), vImagePixelCount(ch), uvStride, vImage_Flags(kvImageNoFlags))
            } }
        } else {
            // 10-bit little-endian in the low bits → P010 (high bits)
            for r in 0..<h {
                let s = UnsafeRawPointer(src.0 + r * ls.0).assumingMemoryBound(to: UInt16.self)
                let d = (y + r * yStride).assumingMemoryBound(to: UInt16.self)
                for i in 0..<w { d[i] = s[i] << 6 }
            }
            for r in 0..<ch {
                let su = UnsafeRawPointer(src.1 + r * ls.1).assumingMemoryBound(to: UInt16.self)
                let sv = UnsafeRawPointer(src.2 + r * ls.2).assumingMemoryBound(to: UInt16.self)
                let d = (uv + r * uvStride).assumingMemoryBound(to: UInt16.self)
                for i in 0..<cw { d[2 * i] = su[i] << 6; d[2 * i + 1] = sv[i] << 6 }
            }
        }
        // colour: the stream's own tags (ISO/IEC 23091-4 code points), else BT.601 for SD and BT.709 above
        let sd = h < 720
        let matrix = f.colorspace != AVCOL_SPC_UNSPECIFIED ? Int32(f.colorspace.rawValue) : (sd ? 6 : 1)
        let prim = f.color_primaries != AVCOL_PRI_UNSPECIFIED ? Int32(f.color_primaries.rawValue) : (sd ? 6 : 1)
        let trc = f.color_trc != AVCOL_TRC_UNSPECIFIED ? Int32(f.color_trc.rawValue) : 1
        for (key, value) in [(kCVImageBufferYCbCrMatrixKey, CVYCbCrMatrixGetStringForIntegerCodePoint(matrix)),
                             (kCVImageBufferColorPrimariesKey, CVColorPrimariesGetStringForIntegerCodePoint(prim)),
                             (kCVImageBufferTransferFunctionKey, CVTransferFunctionGetStringForIntegerCodePoint(trc))] {
            if let v = value?.takeUnretainedValue() { CVBufferSetAttachment(px, key, v, .shouldPropagate) }
        }
        DisplayTone.apply(px)
        if displaySize.width != CGFloat(width) {
            CVBufferSetAttachment(px, kCVImageBufferPixelAspectRatioKey,
                                  [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(displaySize.width),
                                   kCVImageBufferPixelAspectRatioVerticalSpacingKey: width] as CFDictionary, .shouldPropagate)
        }
        return px
    }
}

// MARK: - Playback

/// Software-decoded video into a sample-buffer display layer, with audio from FFAudio (or the Matroska
/// path), both on one render synchronizer, like NativePlayback. Times are stream seconds throughout.
final class FFPlayback: Playback {
    private let video: FFVideo
    private let display = AVSampleBufferDisplayLayer()
    private var sound: SyncedAudio?
    private let sync = AVSampleBufferRenderSynchronizer()
    private let q = DispatchQueue(label: "flick.ff.video", qos: .userInitiated)
    private let wanted = Latest()                  // newest seek; a decode for an older one stops
    // on q
    private var hideBefore = -Double.infinity      // pictures that end before this are decoded, not shown
    private var queued: [Double] = []              // pts of pictures the layer holds that aren't on screen yet
    private var shown: [(at: Double, pts: Double)] = []   // handed to the layer, newest last (to know what's on screen)
    private var ended = false
    private var lastEnd = -Double.infinity         // end of the latest picture ever decoded
    private let dataEnd = Locked(Double.infinity)  // where the pictures really stop (truncated files), once known
    private var pumpPending = false
    private var flushedGen = -1
    private var targetQueuedGen = -1
    private var endTimer: Timer?
    private let pace = Locked((rate: Float(1), playing: false))   // set on main, read on q too
    private(set) var isPlaying: Bool { get { pace.value.playing } set { pace.value.playing = newValue } }
    private var rate: Float { get { pace.value.rate } set { pace.value.rate = newValue } }
    let duration: Double
    let start: Double
    let displaySize: CGSize
    var frameDuration: Double { video.frameDuration }
    var onEnd: (() -> Void)?
    var layer: CALayer { display }
    var isSuspended: Bool { false }
    func suspend() {}                              // SD software decode holds a few small frames only

    /// Opens and probes the file (tens of ms, so off the main thread); for Matroska the caller can pass the
    /// audio it already has.
    static func open(_ url: URL, audio source: AudioSource? = nil) -> (FFVideo, AudioSource?)? {
        guard let v = FFVideo(url: url), v.supported else { return nil }
        if let source { return (v, source) }
        return (v, FFDemux(url: url, type: AVMEDIA_TYPE_AUDIO).flatMap { d in FFAudio(parameters: d.parameters, feed: d) })
    }

    /// On the main thread: it makes the layers.
    init(video v: FFVideo, audio source: AudioSource?) {
        video = v
        start = v.demux.startSeconds
        duration = v.demux.duration
        displaySize = v.displaySize
        display.videoGravity = .resizeAspect
        sync.addRenderer(display.sampleBufferRenderer)
        sound = source.flatMap { SyncedAudio(source: $0, sync: sync) }
        sync.delaysRateChangeUntilHasSufficientMediaData = false
        go(to: 0)
    }

    var currentSeconds: Double { max(0, sync.currentTime().seconds - start) }
    /// Where the pictures really stop: the stated length, or sooner when the file is cut short.
    private var end: Double { min(duration, dataEnd.value - start) }
    private var level: (volume: Float, muted: Bool) = (1, false)       // kept when there's no audio
    var volume: Float { get { sound?.volume ?? level.volume } set { level.volume = newValue; sound?.volume = newValue } }
    var isMuted: Bool { get { sound?.isMuted ?? level.muted } set { level.muted = newValue; sound?.isMuted = newValue } }

    func play(rate r: Float) {
        rate = r
        if currentSeconds >= end - 0.05 { seek(to: 0) { _ in } }
        isPlaying = true
        endTimer = endWatch(replacing: endTimer, end: { $0.end }, steer: { $0.sound?.steer(rate: $0.rate) })
        if sound == nil { sync.setRate(r, time: sync.currentTime()) }
        let g = wanted.value
        q.async { [self] in sound?.play(rate: r); pump(g) }       // after any reset queued by a seek
    }

    func pause() {
        isPlaying = false
        sync.rate = 0
        sound?.pause()
        endTimer?.invalidate()
    }

    func setRate(_ r: Float) {
        rate = r
        if let sound { sound.setRate(r, playing: isPlaying) } else if isPlaying { sync.rate = r }
        let g = wanted.value
        q.async { [self] in pump(g) }
    }

    func cancelSeeks() { wanted.bump() }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        let wasPlaying = isPlaying
        sync.rate = 0
        go(to: seconds) { [weak self] ok in
            guard let self else { return }
            if wasPlaying && self.isPlaying {
                if let s = self.sound { self.q.async { s.play(rate: self.rate) } }
                else { self.sync.setRate(self.rate, time: self.sync.currentTime()) }
            }
            completion(ok)
        }
    }

    /// One frame forward or back from the picture on screen.
    func step(_ n: Int) {
        let now = sync.currentTime().seconds
        let onScreen = q.sync { shown.last { $0.at <= now + 0.001 }?.pts } ?? now
        seek(to: onScreen - start + Double(n) * frameDuration + frameDuration * 0.5) { _ in }
    }

    func teardown() {
        pause()
        wanted.bump()
        display.sampleBufferRenderer.stopRequestingMediaData()
        sound?.stop()
    }

    // MARK: feeding

    private func go(to seconds: Double, completion: ((Bool) -> Void)? = nil) {
        let g = wanted.bump()
        let target = start + min(max(0, seconds), max(0, duration - 0.001))
        q.async { [self] in
            guard g == wanted.value else { DispatchQueue.main.async { completion?(false) }; return }
            display.sampleBufferRenderer.stopRequestingMediaData()
            flushedGen = -1
            display.sampleBufferRenderer.flush(removingDisplayedImage: true) { [weak self] in self?.q.async { self?.flushedGen = g } }
            sync.setRate(0, time: CMTime(seconds: target, preferredTimescale: 90000))
            queued = []; shown = []
            ended = false
            pumpPending = false
            hideBefore = target
            video.seek(to: target)
            // audio waits (paused) at the exact target until play resumes
            sound?.pause()
            sound?.reset(at: target)
            pump(g)
            if let completion { waitForPicture(g, deadline: CACurrentMediaTime() + 3, completion) }
        }
    }

    private var lead: Int { max(3, Int((0.1 * Double(max(rate, 1)) / frameDuration).rounded(.up))) }

    private func pump(_ g: Int, timer: Bool = false) {
        if timer { pumpPending = false }
        guard g == wanted.value else { return }
        let now = sync.currentTime().seconds
        queued.removeAll { $0 <= now }
        if shown.count > 64 { shown.removeFirst(shown.count - 64) }
        while !ended && queued.count < lead {
            let hide = hideBefore
            var seen = -Double.infinity
            guard let (px, pts, dur) = video.next(skip: { p, d in seen = max(seen, p + d); return p + d <= hide + 0.0005 },
                                                  abort: { [wanted] in g != wanted.value })
            else {
                guard g == wanted.value else { break }
                ended = true
                lastEnd = max(lastEnd, seen)
                dataEnd.value = lastEnd
                // nothing at or after the target (the file stops before its stated length): show the last picture
                if targetQueuedGen != g && lastEnd > start && hideBefore > lastEnd - 0.001 {
                    let back = lastEnd - frameDuration * 1.5
                    hideBefore = back
                    video.seek(to: back)
                    ended = false
                    continue
                }
                break
            }
            lastEnd = max(lastEnd, pts + dur)
            enqueue(px, pts, dur, g)
        }
        // playing, not only while the clock runs: after Play the clock starts once the sound is heard
        // (a quarter second later), and a pump that waited for it would never come back
        if (sync.rate > 0 || isPlaying) && !pumpPending && !ended {
            pumpPending = true
            let wait = Double(max(1, lead / 2)) * frameDuration / Double(max(sync.rate, rate, 0.25))
            q.asyncAfter(deadline: .now() + wait) { [weak self] in self?.pump(g, timer: true) }
        }
    }

    private func enqueue(_ px: CVPixelBuffer, _ pts: Double, _ dur: Double, _ g: Int) {
        var f: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: px, formatDescriptionOut: &f)
        // the first picture after a seek can start a little before the target: show it at the target
        let t = targetQueuedGen == g ? pts : max(pts, hideBefore)
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: dur, preferredTimescale: 90000),
                                        presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 90000), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard let f else { return }
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: px, formatDescription: f, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        display.sampleBufferRenderer.enqueue(sb)
        queued.append(t)
        shown.append((t, pts))
        targetQueuedGen = g
    }

    private func waitForPicture(_ g: Int, deadline: Double, _ completion: @escaping (Bool) -> Void) {
        guard g == wanted.value else { DispatchQueue.main.async { completion(false) }; return }
        let done: Bool
        if #available(macOS 14.4, *) {
            done = flushedGen == g && targetQueuedGen == g && display.sampleBufferRenderer.displayedPixelBuffer() != nil
        } else { done = targetQueuedGen == g && flushedGen == g }
        if done || ended || CACurrentMediaTime() > deadline {
            DispatchQueue.main.async { completion(true) }
            return
        }
        q.asyncAfter(deadline: .now() + 0.004) { [weak self] in self?.waitForPicture(g, deadline: deadline, completion) }
    }
}


// MARK: - Sound only

/// Files with no pictures (Opus, Ogg, APE, DTS…): FFAudio through the same audio output, clocked by a
/// render synchronizer with no renderers so the seek bar and speed work as for video.
final class FFAudioPlayback: Playback {
    private let source: FFAudio                    // keeps its demuxer
    private let sound: SyncedAudio
    private let sync = AVSampleBufferRenderSynchronizer()
    private let host = CALayer()
    private var endTimer: Timer?
    private(set) var isPlaying = false
    private var rate: Float = 1
    let duration: Double
    let start: Double
    var onEnd: (() -> Void)?
    var layer: CALayer { host }
    var isSuspended: Bool { false }
    func suspend() {}

    /// Opens and probes the file off the main thread.
    static func open(_ url: URL) -> (FFDemux, FFAudio)? {
        guard let d = FFDemux(url: url, type: AVMEDIA_TYPE_AUDIO), let a = FFAudio(parameters: d.parameters, feed: d) else { return nil }
        return (d, a)
    }

    init?(demux d: FFDemux, audio a: FFAudio) {
        guard let s = SyncedAudio(source: a, sync: sync) else { return nil }
        source = a
        sound = s
        start = d.startSeconds
        duration = d.duration
        sync.setRate(0, time: CMTime(seconds: start, preferredTimescale: 1_000_000_000))
        // queued on the audio queue now, so a seek made right after opening (resuming) lands after it
        sound.reset(at: start)
    }

    var currentSeconds: Double { max(0, sync.currentTime().seconds - start) }
    var volume: Float { get { sound.volume } set { sound.volume = newValue } }
    var isMuted: Bool { get { sound.isMuted } set { sound.isMuted = newValue } }
    /// Where the sound really stops: the stated length, or sooner when the file is cut short.
    private var end: Double { min(duration > 0 ? duration : .infinity, source.soundEnd.value - start) }

    // SyncedAudio queues every call on its own queue in order, so a play always follows the reset before it

    func play(rate r: Float) {
        rate = r
        if currentSeconds >= end - 0.05 { seek(to: 0) { _ in } }
        isPlaying = true
        endTimer = endWatch(replacing: endTimer, end: { $0.end }, steer: { $0.sound.steer(rate: $0.rate) })
        sound.play(rate: r)
    }

    func pause() {
        isPlaying = false
        sound.cancelClock()
        sync.rate = 0
        sound.pause()
        endTimer?.invalidate()
    }

    func setRate(_ r: Float) {
        rate = r
        sound.setRate(r, playing: isPlaying)
    }

    func cancelSeeks() {}

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        let wasPlaying = isPlaying
        sound.cancelClock()
        let target = start + min(max(0, seconds), max(0, (duration > 0 ? duration : seconds) - 0.001))
        sync.setRate(0, time: CMTime(seconds: target, preferredTimescale: 1_000_000_000))
        sound.pause()
        sound.reset(at: target)
        if wasPlaying { sound.play(rate: rate) }
        DispatchQueue.main.async { completion(true) }
    }

    func teardown() {
        pause()
        sound.stop()
    }
}

// MARK: - Preview pictures

/// Thumbnails for the seek bar from FFmpeg-only files: the keyframe before the asked-for time, scaled by
/// a VideoToolbox pixel transfer. Same rules as Thumbnailer: latest request only, a few cached, all
/// released after a few idle seconds.
final class FFThumbnailer: PreviewSource {
    private let url: URL
    private let q = DispatchQueue(label: "flick.ff.thumbs", qos: .userInitiated)
    private let targetWidth: Int
    // on q
    private var video: FFVideo?
    private var transfer: VTPixelTransferSession?
    private var cache: [Int: CGImage] = [:]
    private var order: [Int] = []
    private var wanted: (Double, (CGImage, Int) -> Void)?
    private var busy = false
    private var idle: DispatchWorkItem?
    var spacing: Double = 0

    init(url: URL, width: Int = 384) { self.url = url; targetWidth = width }

    deinit { if let t = transfer { VTPixelTransferSessionInvalidate(t) } }

    func request(seconds t: Double, _ done: @escaping (CGImage, Int) -> Void) {
        let gap = spacing
        q.async { [self] in
            let k = key(t)
            if let k, let img = cache[k] { DispatchQueue.main.async { done(img, k) }; return }
            wanted = (t, done)
            if !busy { next(gap) }
        }
    }

    /// The keyframe's time in ms, when the demuxer's index already knows it.
    private func key(_ t: Double) -> Int? {
        guard let v = video else { return nil }
        let s = v.demux.avStream
        let ts = Int64((v.demux.startSeconds + t) / av_q2d(v.demux.timeBase))
        guard let e = avformat_index_get_entry_from_timestamp(s, ts, AVSEEK_FLAG_BACKWARD) else { return nil }
        return Int(Double(e.pointee.timestamp) * av_q2d(v.demux.timeBase) * 1000)
    }

    private func next(_ gap: Double) {
        guard let (t, done) = wanted else { busy = false; scheduleIdle(); return }
        wanted = nil
        busy = true
        if video == nil { video = FFVideo(url: url, threads: false) }
        if let v = video {
            v.seek(to: v.demux.startSeconds + t)
            if let (px, pts, _) = v.next(), let img = image(px, v) {
                let k = key(t) ?? Int(pts * 1000)
                cache[k] = img
                if let i = order.firstIndex(of: k) { order.remove(at: i) }
                order.append(k)
                while order.count > 24 { cache[order.removeFirst()] = nil }
                DispatchQueue.main.async { done(img, k) }
            }
        }
        if gap > 0 { q.asyncAfter(deadline: .now() + gap) { [self] in next(spacing) } } else { next(0) }
    }

    private func image(_ px: CVPixelBuffer, _ v: FFVideo) -> CGImage? {
        let w = min(targetWidth, Int(v.displaySize.width)) & ~1
        let h = (w * Int(v.displaySize.height) / max(1, Int(v.displaySize.width))) & ~1
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
        guard let t = transfer, let out, VTPixelTransferSessionTransferImage(t, from: px, to: out) == noErr else { return nil }
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(out, options: nil, imageOut: &img)
        return img
    }

    private func scheduleIdle() {
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            self.video = nil
            if let t = self.transfer { VTPixelTransferSessionInvalidate(t) }
            self.transfer = nil
            self.cache = [:]; self.order = []
        }
        idle = w
        q.asyncAfter(deadline: .now() + 4, execute: w)
    }
}
