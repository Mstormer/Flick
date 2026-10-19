import AudioToolbox
import CoreMedia
import CoreVideo

/// Matroska codec IDs → CoreMedia format descriptions. Anything returning nil falls back to the remuxer.
enum MKVCodecs {
    static func videoFormat(_ t: MKVFile.Track) -> CMVideoFormatDescription? {
        let (codec, atom): (CMVideoCodecType, String)
        switch t.codecID {
        case "V_MPEG4/ISO/AVC": (codec, atom) = (kCMVideoCodecType_H264, "avcC")
        case "V_MPEGH/ISO/HEVC": (codec, atom) = (kCMVideoCodecType_HEVC, "hvcC")
        case "V_AV1": (codec, atom) = (kCMVideoCodecType_AV1, "av1C")
        default: return nil
        }
        guard let cp = t.codecPrivate, t.width > 0, t.height > 0 else { return nil }
        var ext: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: cp]]
        if t.primaries != 2, let p = CVColorPrimariesGetStringForIntegerCodePoint(Int32(t.primaries))?.takeUnretainedValue() {
            ext[kCMFormatDescriptionExtension_ColorPrimaries] = p
        }
        if t.transfer != 2, let p = CVTransferFunctionGetStringForIntegerCodePoint(Int32(t.transfer))?.takeUnretainedValue() {
            ext[kCMFormatDescriptionExtension_TransferFunction] = p
        }
        if t.matrix != 2, let p = CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(t.matrix))?.takeUnretainedValue() {
            ext[kCMFormatDescriptionExtension_YCbCrMatrix] = p
        }
        if t.range == 2 { ext[kCMFormatDescriptionExtension_FullRangeVideo] = true }
        if t.displayWidth > 0, t.displayHeight > 0, t.displayWidth * t.height != t.displayHeight * t.width {
            ext[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: t.displayWidth * t.height,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: t.displayHeight * t.width]
        }
        var f: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: Int32(t.width), height: Int32(t.height),
                                             extensions: ext as CFDictionary, formatDescriptionOut: &f) == noErr else { return nil }
        return f
    }

    /// Audio the system decoders handle. `isPCM` tells the feeder to build sample buffers per frame.
    static func audioFormat(_ t: MKVFile.Track) -> (CMAudioFormatDescription, isPCM: Bool)? {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = t.sampleRate
        asbd.mChannelsPerFrame = UInt32(t.channels)
        var cookie: Data? = nil
        var pcm = false
        switch t.codecID {
        case let id where id.hasPrefix("A_AAC"):
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFramesPerPacket = 1024
            cookie = t.codecPrivate.map(esds) ?? esds(asc(t))
        case "A_AC3": asbd.mFormatID = kAudioFormatAC3; asbd.mFramesPerPacket = 1536
        case "A_EAC3": asbd.mFormatID = kAudioFormatEnhancedAC3; asbd.mFramesPerPacket = 1536
        case "A_MPEG/L3": asbd.mFormatID = kAudioFormatMPEGLayer3; asbd.mFramesPerPacket = 1152
        case "A_MPEG/L2": asbd.mFormatID = kAudioFormatMPEGLayer2; asbd.mFramesPerPacket = 1152
        case "A_OPUS":
            asbd.mFormatID = kAudioFormatOpus
            asbd.mSampleRate = 48000
            asbd.mFramesPerPacket = 960
            cookie = t.codecPrivate
        case "A_FLAC":
            asbd.mFormatID = kAudioFormatFLAC
            cookie = t.codecPrivate.map(flacCookie)
            if let c = cookie, c.count >= 4 + 4 + 18 {
                // STREAMINFO: max block size (frames per packet) and bits per sample
                let si = c.startIndex + 8
                asbd.mFramesPerPacket = UInt32(c[si + 2]) << 8 | UInt32(c[si + 3])
                let bps = Int((c[si + 12] & 0x01) << 4 | c[si + 13] >> 4) + 1
                asbd.mFormatFlags = [16: 1, 20: 2, 24: 3, 32: 4][bps] ?? 1
            }
        case "A_ALAC":
            asbd.mFormatID = kAudioFormatAppleLossless
            cookie = t.codecPrivate
        case "A_PCM/INT/LIT", "A_PCM/FLOAT/IEEE":
            pcm = true
            let bits = t.bitDepth > 0 ? t.bitDepth : 16
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = t.codecID.contains("FLOAT") ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                                                             : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            asbd.mBitsPerChannel = UInt32(bits)
            asbd.mBytesPerFrame = UInt32(bits / 8 * t.channels)
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
            asbd.mFramesPerPacket = 1
        default:
            return nil   // DTS, TrueHD, Vorbis…: not decodable by the system
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = [1: kAudioChannelLayoutTag_Mono, 2: kAudioChannelLayoutTag_Stereo,
                                    6: kAudioChannelLayoutTag_MPEG_5_1_A, 8: kAudioChannelLayoutTag_MPEG_7_1_C][t.channels]
                                    ?? (kAudioChannelLayoutTag_DiscreteInOrder | UInt32(t.channels))
        var f: CMAudioFormatDescription?
        let status: OSStatus = cookie.map { c in
            c.withUnsafeBytes { b in
                CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                               magicCookieSize: c.count, magicCookie: b.baseAddress, extensions: nil, formatDescriptionOut: &f)
            }
        } ?? CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &f)
        guard status == noErr, let f else { return nil }
        return (f, pcm)
    }

    /// AudioSpecificConfig for legacy "A_AAC/MPEG4/LC"-style IDs that carry no CodecPrivate.
    private static func asc(_ t: MKVFile.Track) -> Data {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let idx = rates.firstIndex(of: t.sampleRate) ?? 4
        let obj: UInt16 = t.codecID.contains("SBR") ? 5 : 2
        let v = obj << 11 | UInt16(idx) << 7 | UInt16(t.channels & 0xF) << 3
        return Data([UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    /// Wrap an AudioSpecificConfig in the MPEG-4 ES descriptor AudioToolbox expects as an AAC cookie.
    private static func esds(_ asc: Data) -> Data {
        func desc(_ tag: UInt8, _ body: Data) -> Data {
            var d = Data([tag]); var n = body.count
            var len: [UInt8] = []
            repeat { len.insert(UInt8(n & 0x7F), at: 0); n >>= 7 } while n > 0
            for i in 0..<(len.count - 1) { len[i] |= 0x80 }
            d.append(contentsOf: len); d.append(body); return d
        }
        let dsi = desc(0x05, asc)
        var dcd = Data([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]); dcd.append(dsi)
        var es = Data([0, 0, 0]); es.append(desc(0x04, dcd)); es.append(desc(0x06, Data([0x02])))
        return desc(0x03, es)
    }

    /// Matroska stores "fLaC" + metadata blocks; AudioToolbox wants the MP4 'dfLa' body:
    /// version/flags, then just the STREAMINFO block marked as the last one.
    private static func flacCookie(_ cp: Data) -> Data {
        var blocks = Data(cp.starts(with: Array("fLaC".utf8)) ? cp.dropFirst(4) : cp)
        guard blocks.count >= 38 else { return blocks }
        blocks = blocks.prefix(38)
        blocks[blocks.startIndex] = 0x80        // STREAMINFO, last-metadata-block flag set
        return Data([0, 0, 0, 0]) + blocks
    }
}
