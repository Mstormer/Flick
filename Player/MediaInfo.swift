import AppKit
import AVFoundation
import CFFmpeg

/// What the I key shows: the file, then each video, audio and subtitle track. Read with whatever can open
/// the file: AVFoundation for MP4/MOV, the Matroska parser for MKV/WebM, libavformat for the rest.
struct MediaInfo {
    struct Section { var title: String; var rows: [(String, String)] }
    var sections: [Section] = []

    @MainActor static func load(_ url: URL, mkv: MKVFile?, decoder: String) async -> MediaInfo {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var info: MediaInfo
        var container = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.localizedDescription) ?? url.pathExtension.uppercased()
        var duration = 0.0
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) == true
        var m = mkv
        if !playable && m == nil { m = await Task.detached { MKVFile(url: url) }.value }
        if playable {
            (info, duration) = await fromAsset(asset)
        } else if let m {
            (info, duration) = fromMKV(m)
            container = url.pathExtension.lowercased() == "webm" ? "WebM" : "Matroska"
        } else {
            (info, duration, container) = await Task.detached { fromFFmpeg(url) }.value
        }
        var general: [(String, String)] = [("Name", url.lastPathComponent), ("Container", container), ("Size", bytes(size))]
        if duration > 0 {
            general.append(("Duration", ControlBar.fmt(duration)))
            general.append(("Bitrate", rate(Double(size) * 8 / duration)))
        }
        general.append(("Decoding", decoder))
        // video, then audio, then subtitles, whatever order the file stores its streams in
        let order = ["Video": 0, "Audio": 1, "Subtitles": 2]
        info.sections = info.sections.enumerated().sorted { (order[$0.element.title] ?? 3, $0.offset) < (order[$1.element.title] ?? 3, $1.offset) }.map(\.element)
        info.sections.insert(Section(title: "File", rows: general), at: 0)
        return info
    }

    // MARK: AVFoundation

    private static func fromAsset(_ a: AVURLAsset) async -> (MediaInfo, Double) {
        var info = MediaInfo()
        let duration = (try? await a.load(.duration).seconds) ?? 0
        for t in (try? await a.loadTracks(withMediaType: .video)) ?? [] {
            guard let f = try? await t.load(.formatDescriptions).first else { continue }
            var rows = [("Codec", videoCodec(f))]
            let size = (try? await t.load(.naturalSize)) ?? .zero
            rows.append(("Resolution", "\(Int(size.width)) × \(Int(size.height))"))
            if let fps = try? await t.load(.nominalFrameRate), fps > 0 { rows.append(("Frame rate", frames(Double(fps)))) }
            rows += colour(f)
            if let r = try? await t.load(.estimatedDataRate), r > 0 { rows.append(("Bitrate", rate(Double(r)))) }
            info.sections.append(Section(title: "Video", rows: rows))
        }
        let audios = (try? await a.loadTracks(withMediaType: .audio)) ?? []
        for t in audios {
            guard let f = try? await t.load(.formatDescriptions).first else { continue }
            var rows = [("Codec", audioCodec(f))]
            if let d = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                rows.append(("Channels", layoutName(f) ?? channels(Int(d.mChannelsPerFrame))))
                rows.append(("Sample rate", hz(d.mSampleRate)))
                if d.mFormatID == kAudioFormatLinearPCM, d.mBitsPerChannel > 0 { rows.append(("Bit depth", "\(d.mBitsPerChannel)-bit")) }
                if [kAudioFormatAppleLossless, kAudioFormatFLAC].contains(d.mFormatID), let b = [1: 16, 2: 20, 3: 24, 4: 32][Int(d.mFormatFlags)] {
                    rows.append(("Bit depth", "\(b)-bit"))
                }
            }
            if let r = try? await t.load(.estimatedDataRate), r > 0 { rows.append(("Bitrate", rate(Double(r)))) }
            var lang = try? await t.load(.extendedLanguageTag)
            if lang == nil { lang = try? await t.load(.languageCode) }
            if let l = lang ?? nil, let name = language(l) { rows.append(("Language", name)) }
            if audios.count > 1 { rows.append(("Playing", (try? await t.load(.isEnabled)) == true ? "Yes" : "No")) }
            info.sections.append(Section(title: "Audio", rows: rows))
        }
        let subs = (try? await a.loadMediaSelectionGroup(for: .legible))?.options.map(\.displayName) ?? []
        if !subs.isEmpty { info.sections.append(Section(title: "Subtitles", rows: [("Tracks", subs.joined(separator: ", "))])) }
        return (info, duration)
    }

    private static func atom(_ f: CMFormatDescription, _ key: String) -> Data? {
        (CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any])?[key] as? Data
    }

    static func videoCodec(_ f: CMFormatDescription) -> String {
        let sub = CMFormatDescriptionGetMediaSubType(f)
        switch fourCC(sub) {
        case "avc1", "avc3": return avc(atom(f, "avcC"))
        case "hvc1", "hev1", "dvh1", "dvhe":
            var s = hevc(atom(f, "hvcC"))
            if atom(f, "dvcC") != nil || atom(f, "dvvC") != nil || ["dvh1", "dvhe"].contains(fourCC(sub)) { s += ", Dolby Vision" }
            return s
        case "av01":
            guard let c = atom(f, "av1C"), c.count > 1 else { return "AV1" }
            return "AV1 " + (["Main", "High", "Professional"][safe: Int(c[c.startIndex + 1] >> 5)] ?? "")
        case "vp09":
            guard let c = atom(f, "vpcC"), c.count > 6 else { return "VP9" }
            return "VP9 Profile \(c[c.startIndex + 4]), \(c[c.startIndex + 6] >> 4)-bit"
        case "vp08": return "VP8"
        case "apch": return "Apple ProRes 422 HQ"
        case "apcn": return "Apple ProRes 422"
        case "apcs": return "Apple ProRes 422 LT"
        case "apco": return "Apple ProRes 422 Proxy"
        case "ap4h": return "Apple ProRes 4444"
        case "ap4x": return "Apple ProRes 4444 XQ"
        case "aprn", "aprh": return "Apple ProRes RAW"
        case "mp4v": return "MPEG-4 Part 2"
        case "mp2v", "mpg2", "hdv1", "hdv2", "hdv3", "xdv7", "xdva": return "MPEG-2"
        case "mp1v": return "MPEG-1"
        case "jpeg", "mjpa", "mjpb": return "Motion JPEG"
        case "h263", "s263": return "H.263"
        default: return fourCC(sub)
        }
    }

    /// Profile and level from an avcC record (MP4 'avcC' box or Matroska CodecPrivate).
    static func avc(_ c: Data?) -> String {
        guard let c, c.count > 3 else { return "H.264 (AVC)" }
        let p = [66: "Baseline", 77: "Main", 88: "Extended", 100: "High", 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4"][Int(c[c.startIndex + 1])]
        return "H.264 (AVC)" + (p.map { " \($0)" } ?? "") + String(format: " @ L%.1f", Double(c[c.startIndex + 3]) / 10)
    }

    /// The same from an hvcC record.
    static func hevc(_ c: Data?) -> String {
        guard let c, c.count > 12 else { return "H.265 (HEVC)" }
        let p = [1: "Main", 2: "Main 10", 3: "Main Still Picture", 4: "Range Extensions"][Int(c[c.startIndex + 1] & 0x1F)]
        return "H.265 (HEVC)" + (p.map { " \($0)" } ?? "") + String(format: " @ L%g", Double(c[c.startIndex + 12]) / 30)
    }

    static func audioCodec(_ f: CMFormatDescription) -> String {
        let id = CMFormatDescriptionGetMediaSubType(f)
        switch id {
        case kAudioFormatMPEG4AAC:
            var size = 0
            guard let p = CMAudioFormatDescriptionGetMagicCookie(f, sizeOut: &size), size > 0 else { return "AAC" }
            return aac(Data(bytes: p, count: size))
        case kAudioFormatMPEG4AAC_HE: return "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2: return "HE-AAC v2"
        case kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: return "AAC (low delay)"
        case kAudioFormatAppleLossless: return "Apple Lossless (ALAC)"
        case kAudioFormatAC3: return "Dolby Digital (AC-3)"
        case kAudioFormatEnhancedAC3: return "Dolby Digital Plus (E-AC-3)"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEGLayer2: return "MPEG Layer II"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatAppleIMA4: return "IMA 4:1"
        default: return fourCC(id)
        }
    }

    /// The AAC profile from an AudioSpecificConfig (first 5 bits), found inside an MPEG-4 ES descriptor
    /// (MP4 'esds' cookie: the DecoderSpecificInfo, tag 5) or given bare (Matroska CodecPrivate).
    static func aac(_ d: Data) -> String {
        let b = [UInt8](d)
        var i = 0
        func length() -> Int {                              // descriptor size: 7 bits per byte, high bit = more
            var n = 0
            while i < b.count { let x = b[i]; i += 1; n = n << 7 | Int(x & 0x7F); if x & 0x80 == 0 { break } }
            return n
        }
        var asc = 0
        if b.first == 0x03 {                                // ES_Descriptor → DecoderConfigDescriptor → DecoderSpecificInfo
            i = 1; _ = length()
            guard i + 3 <= b.count else { return "AAC" }
            let flags = b[i + 2]; i += 3
            if flags & 0x80 != 0 { i += 2 }
            if flags & 0x40 != 0, i < b.count { i += 1 + Int(b[i]) }
            if flags & 0x20 != 0 { i += 2 }
            guard i < b.count, b[i] == 0x04 else { return "AAC" }
            i += 1; _ = length(); i += 13
            guard i < b.count, b[i] == 0x05 else { return "AAC" }
            i += 1; _ = length()
            asc = i
        }
        guard asc < b.count else { return "AAC" }
        let names = [1: "AAC Main", 2: "AAC-LC", 3: "AAC SSR", 4: "AAC LTP", 5: "HE-AAC", 23: "AAC-LD", 29: "HE-AAC v2", 39: "AAC-ELD"]
        return names[Int(b[asc] >> 3)] ?? "AAC"
    }

    /// The channel layout's own name ("5.1 (L R C LFE Ls Rs)"), when the file declares one.
    private static func layoutName(_ f: CMAudioFormatDescription) -> String? {
        var size = 0
        guard let l = CMAudioFormatDescriptionGetChannelLayout(f, sizeOut: &size), size > 0 else { return nil }
        var name: Unmanaged<CFString>?
        var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutName, UInt32(size), l, &n, &name) == noErr,
              let s = name?.takeRetainedValue() as String?, !s.isEmpty else { return nil }
        return s
    }

    /// Bit depth and HDR from the format description's colour tags.
    private static func colour(_ f: CMFormatDescription) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let d = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int { rows.append(("Bit depth", "\(d)-bit")) }
        let tf = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        let prim = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { rows.append(("HDR", "HDR10 (PQ)")) }
        else if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { rows.append(("HDR", "HLG")) }
        if let prim { rows.append(("Colour", prim.replacingOccurrences(of: "ITU_R_", with: "BT.").replacingOccurrences(of: "_", with: " "))) }
        return rows
    }

    // MARK: Matroska

    private static func fromMKV(_ m: MKVFile) -> (MediaInfo, Double) {
        var info = MediaInfo()
        let d = m.duration
        func bitrate(_ t: MKVFile.Track) -> String? {
            guard d > 0, let n = m.totals[t.number], n.count > 0 else { return nil }
            return rate(Double(n.bytes) * 8 / d)
        }
        // the track NativePlayback plays: the default one if anything decodes it, else the first that decodes
        let audio = m.audioTracks
        let decodes = { (t: MKVFile.Track) in MKVCodecs.audioFormat(t) != nil || MKVCodecs.ffAudioCodec(t) != nil }
        let playing = (audio.filter(\.isDefault) + audio).first(where: decodes)?.number
        for t in m.tracks {
            var rows: [(String, String)] = []
            switch t.type {
            case 1:
                // the format description playback builds carries profile, level, bit depth and colour
                let first = m.totals[t.number]?.first.map { UnsafeRawBufferPointer(start: m.base + Int($0.offset), count: Int($0.size)) }
                if let f = MKVCodecs.videoFormat(t, firstFrame: first) {
                    rows.append(("Codec", videoCodec(f)))
                } else {
                    rows.append(("Codec", t.codecID == "V_MS/VFW/FOURCC" ? vfw(t.codecPrivate) : mkvCodec(t.codecID)))
                }
                rows.append(("Resolution", "\(t.width) × \(t.height)"))
                if t.displayWidth > 0, t.displayHeight > 0, t.displayWidth * t.height != t.displayHeight * t.width {
                    rows.append(("Display size", "\(t.displayWidth) × \(t.displayHeight)"))
                }
                if t.defaultDuration > 0 { rows.append(("Frame rate", frames(1e9 / Double(t.defaultDuration)))) }
                else if let n = m.totals[t.number]?.count, n > 1, d > 0 { rows.append(("Frame rate", frames(Double(n) / d))) }
                if t.transfer == 16 { rows.append(("HDR", "HDR10 (PQ)")) } else if t.transfer == 18 { rows.append(("HDR", "HLG")) }
                if t.primaries == 9 { rows.append(("Colour", "BT.2020")) }
                if let b = bitrate(t) { rows.append(("Bitrate", b)) }
                info.sections.append(Section(title: "Video", rows: rows))
            case 2:
                rows.append(("Codec", t.codecID.hasPrefix("A_AAC") && t.codecPrivate?.isEmpty == false ? aac(t.codecPrivate!) : mkvCodec(t.codecID)))
                rows.append(("Channels", channels(t.channels)))
                rows.append(("Sample rate", hz(t.sampleRate)))
                // bit depth means something only for lossless audio
                if t.bitDepth > 0, ["A_FLAC", "A_ALAC", "A_TRUEHD", "A_MLP", "A_DTS/LOSSLESS"].contains(t.codecID) || t.codecID.hasPrefix("A_PCM") {
                    rows.append(("Bit depth", "\(t.bitDepth)-bit"))
                }
                if let b = bitrate(t) { rows.append(("Bitrate", b)) }
                rows.append(("Decoder", MKVCodecs.audioFormat(t) != nil ? "macOS" : MKVCodecs.ffAudioCodec(t) != nil ? "FFmpeg" : "Not supported"))
                rows += trackLabels(t)
                if audio.count > 1 { rows.append(("Playing", t.number == playing ? "Yes" : "No")) }
                info.sections.append(Section(title: "Audio", rows: rows))
            case 17:
                rows.append(("Format", mkvCodec(t.codecID)))
                rows += trackLabels(t)
                info.sections.append(Section(title: "Subtitles", rows: rows))
            default: break
            }
        }
        return (info, d)
    }

    /// Video for Windows in Matroska: the codec is the FourCC in the BITMAPINFOHEADER (biCompression).
    private static func vfw(_ cp: Data?) -> String {
        guard let cp, cp.count >= 20 else { return "Video for Windows" }
        let b = cp.startIndex + 16
        let cc = String(bytes: cp[b..<b + 4], encoding: .ascii)?.uppercased() ?? "?"
        switch cc {
        case "WVC1", "WMVA": return "VC-1"
        case "WMV3": return "Windows Media Video 9"
        case "WMV2": return "Windows Media Video 8"
        case "WMV1": return "Windows Media Video 7"
        case "XVID", "DIVX", "DX50", "FMP4", "MP4V": return "MPEG-4 Part 2 (\(cc))"
        case "MP42", "MP43", "DIV3": return "Microsoft MPEG-4 (\(cc))"
        case "H264", "AVC1", "X264": return "H.264 (AVC)"
        case "MJPG": return "Motion JPEG"
        default: return "Video for Windows (\(cc))"
        }
    }

    private static func trackLabels(_ t: MKVFile.Track) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let l = language(t.language) { rows.append(("Language", l)) }
        if !t.name.isEmpty { rows.append(("Title", t.name)) }
        if t.isDefault { rows.append(("Default", "Yes")) }
        return rows
    }

    static func mkvCodec(_ id: String) -> String {
        switch id {
        case "V_MPEG4/ISO/AVC": return "H.264 (AVC)"
        case "V_MPEGH/ISO/HEVC": return "H.265 (HEVC)"
        case "V_AV1": return "AV1"
        case "V_VP9": return "VP9"
        case "V_VP8": return "VP8"
        case "V_MPEG2": return "MPEG-2"
        case "V_MPEG1": return "MPEG-1"
        case "V_MS/VFW/FOURCC": return "VFW (VC-1, MPEG-4 or other)"
        case let s where s.hasPrefix("V_MPEG4/ISO/"): return "MPEG-4 Part 2"
        case let s where s.hasPrefix("V_PRORES"): return "Apple ProRes"
        case let s where s.hasPrefix("A_AAC"): return "AAC"
        case "A_AC3": return "Dolby Digital (AC-3)"
        case "A_EAC3": return "Dolby Digital Plus (E-AC-3)"
        case "A_DTS": return "DTS"
        case "A_DTS/EXPRESS": return "DTS Express"
        case "A_DTS/LOSSLESS": return "DTS-HD Master Audio"
        case "A_TRUEHD": return "Dolby TrueHD"
        case "A_MLP": return "MLP"
        case "A_OPUS": return "Opus"
        case "A_VORBIS": return "Vorbis"
        case "A_FLAC": return "FLAC"
        case "A_ALAC": return "Apple Lossless (ALAC)"
        case "A_MPEG/L3": return "MP3"
        case "A_MPEG/L2": return "MPEG Layer II"
        case let s where s.hasPrefix("A_PCM"): return "PCM"
        case "S_TEXT/UTF8": return "SubRip (SRT)"
        case "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA": return "ASS/SSA"
        case "S_TEXT/WEBVTT": return "WebVTT"
        case "S_HDMV/PGS": return "PGS (Blu-ray, picture-based)"
        case "S_VOBSUB": return "VobSub (DVD, picture-based)"
        default: return id
        }
    }

    // MARK: libavformat (WMV/ASF)

    private static func fromFFmpeg(_ url: URL) -> (MediaInfo, Double, String) {
        var info = MediaInfo()
        var c: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&c, url.path, nil, nil) >= 0, let ctx = c else { return (info, 0, url.pathExtension.uppercased()) }
        defer { avformat_close_input(&c) }
        avformat_find_stream_info(ctx, nil)
        let container = ctx.pointee.iformat.map { String(cString: $0.pointee.long_name) } ?? url.pathExtension.uppercased()
        let duration = ctx.pointee.duration > 0 ? Double(ctx.pointee.duration) / Double(AV_TIME_BASE) : 0
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let s = ctx.pointee.streams[i] else { continue }
            let p = s.pointee.codecpar.pointee
            var codec = avcodec_descriptor_get(p.codec_id).map { String(cString: $0.pointee.long_name) } ?? String(cString: avcodec_get_name(p.codec_id))
            if let prof = avcodec_profile_name(p.codec_id, p.profile) { codec += " " + String(cString: prof) }
            var rows = [("Codec", codec)]
            switch p.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                rows.append(("Resolution", "\(p.width) × \(p.height)"))
                let fr = s.pointee.avg_frame_rate.num > 0 ? s.pointee.avg_frame_rate : s.pointee.r_frame_rate
                if fr.num > 0, fr.den > 0 { rows.append(("Frame rate", frames(av_q2d(fr)))) }
                if p.field_order != AV_FIELD_PROGRESSIVE && p.field_order != AV_FIELD_UNKNOWN { rows.append(("Scan", "Interlaced")) }
                if p.bit_rate > 0 { rows.append(("Bitrate", rate(Double(p.bit_rate)))) }
                info.sections.append(Section(title: "Video", rows: rows))
            case AVMEDIA_TYPE_AUDIO:
                var layout = p.ch_layout
                var buf = [CChar](repeating: 0, count: 64)
                let described = av_channel_layout_describe(&layout, &buf, buf.count) > 0 && layout.order == AV_CHANNEL_ORDER_NATIVE
                let n = Int(p.ch_layout.nb_channels)
                let name = String(cString: buf)
                rows.append(("Channels", described && n > 2 && name != channels(n) ? "\(channels(n)) (\(name))" : channels(n)))
                rows.append(("Sample rate", hz(Double(p.sample_rate))))
                if p.bits_per_raw_sample > 0 { rows.append(("Bit depth", "\(p.bits_per_raw_sample)-bit")) }
                if p.bit_rate > 0 { rows.append(("Bitrate", rate(Double(p.bit_rate)))) }
                info.sections.append(Section(title: "Audio", rows: rows))
            case AVMEDIA_TYPE_SUBTITLE:
                info.sections.append(Section(title: "Subtitles", rows: [("Format", codec)]))
            default: break
            }
        }
        return (info, duration, container)
    }

    /// Duration only, cheaply (for the playlist): AVFoundation, else the container header via libavformat.
    static func duration(_ url: URL) async -> Double? {
        let a = AVURLAsset(url: url)
        if (try? await a.load(.isPlayable)) == true, let d = try? await a.load(.duration).seconds, d > 0 { return d }
        return await Task.detached {
            var c: UnsafeMutablePointer<AVFormatContext>?
            guard avformat_open_input(&c, url.path, nil, nil) >= 0, let ctx = c else { return nil }
            defer { avformat_close_input(&c) }
            if ctx.pointee.duration <= 0 { avformat_find_stream_info(ctx, nil) }
            return ctx.pointee.duration > 0 ? Double(ctx.pointee.duration) / Double(AV_TIME_BASE) : nil
        }.value
    }

    // MARK: formatting

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func rate(_ bps: Double) -> String { bps >= 1e6 ? String(format: "%.1f Mb/s", bps / 1e6) : String(format: "%.0f kb/s", bps / 1e3) }
    static func hz(_ r: Double) -> String { r.truncatingRemainder(dividingBy: 1000) == 0 ? String(format: "%.0f kHz", r / 1000) : String(format: "%.1f kHz", r / 1000) }
    static func frames(_ f: Double) -> String { abs(f - f.rounded()) < 0.005 ? String(format: "%.0f fps", f) : String(format: "%.3f fps", f) }
    static func channels(_ n: Int) -> String { [1: "Mono", 2: "Stereo", 6: "5.1", 8: "7.1"][n] ?? "\(n) channels" }
    static func language(_ code: String) -> String? {
        guard !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forIdentifier: code) ?? Locale.current.localizedString(forLanguageCode: code) ?? code
    }
    static func fourCC(_ v: FourCharCode) -> String {
        let s = String(bytes: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)], encoding: .macOSRoman) ?? "?"
        return s.trimmingCharacters(in: .whitespaces)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The info overlay (top left): sections of label/value rows on a dark rounded panel.
final class InfoPanel: NSView {
    private let text = NSTextField(wrappingLabelWithString: "")
    private let effect = NSVisualEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        appearance = NSAppearance(named: .darkAqua)
        addSubview(effect)
        text.isSelectable = true
        text.drawsBackground = false
        addSubview(text)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File info")
    }
    required init?(coder: NSCoder) { fatalError() }

    static let width: CGFloat = 340

    func show(_ info: MediaInfo) {
        let s = NSMutableAttributedString()
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let key: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let val: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]
        for (i, sec) in info.sections.enumerated() {
            s.append(NSAttributedString(string: (i > 0 ? "\n" : "") + sec.title + "\n", attributes: head))
            for (k, v) in sec.rows {
                s.append(NSAttributedString(string: k + "\t", attributes: key))
                s.append(NSAttributedString(string: v + "\n", attributes: val))
            }
        }
        if s.length > 0 { s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1)) }
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 88)]
        para.headIndent = 88
        para.paragraphSpacing = 2
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        text.attributedStringValue = s
        setAccessibilityValue(s.string)
        needsLayout = true
    }

    /// Height for the current text at the panel's width.
    var fittingHeight: CGFloat {
        text.preferredMaxLayoutWidth = Self.width - 28
        return ceil(text.intrinsicContentSize.height) + 24
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        text.frame = bounds.insetBy(dx: 14, dy: 12)
    }
}
