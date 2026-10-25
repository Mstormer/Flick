import AppKit
import AVFoundation
import MediaAccessibility

/// One timed caption.
struct Cue {
    var start: Double
    var end: Double
    var text: String
}

/// Something the Subtitles menu can switch to.
enum CaptionSource {
    case embedded(AVMediaSelectionOption)        // rendered by AVPlayer (MP4/MOV text tracks, CEA-608)
    case cues(title: String, cues: [Cue])        // rendered by CaptionOverlay (sidecar files, MKV text tracks)
    case unsupported(title: String)              // e.g. image-based PGS in MKV: listed but not selectable

    var title: String {
        switch self {
        case .embedded(let o): return o.displayName
        case .cues(let t, _), .unsupported(let t): return t
        }
    }
}

// MARK: - Parsing

enum CaptionParser {
    static let sidecarExtensions = ["srt", "vtt", "ass", "ssa"]

    /// Subtitle files next to the video: "Movie.srt", "Movie.en.srt", "Movie.English.vtt"…
    static func sidecars(for video: URL) -> [URL] {
        let dir = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { f in
            sidecarExtensions.contains(f.pathExtension.lowercased()) &&
            (f.deletingPathExtension().lastPathComponent.lowercased() == stem ||
             f.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(stem + "."))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func load(_ url: URL) -> CaptionSource? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        let cues: [Cue]
        switch url.pathExtension.lowercased() {
        case "vtt": cues = vtt(text)
        case "ass", "ssa": cues = ass(text)
        default: cues = srt(text)
        }
        guard !cues.isEmpty else { return nil }
        // "Movie.en.srt" → "en (srt file)"; "Movie.srt" → "Movie.srt"
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".")
        let lang = parts.count > 1 ? String(parts.last!) : nil
        let title = lang.map { "\(Locale.current.localizedString(forLanguageCode: $0) ?? $0) — \(url.lastPathComponent)" } ?? url.lastPathComponent
        return .cues(title: title, cues: cues)
    }

    /// "00:01:02,345", "01:02.345", "0:01:02.34" → seconds
    static func time(_ s: Substring) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var t = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; t = t * 60 + v }
        return t
    }

    /// Remove markup we don't style: HTML-ish tags, ASS override blocks; turn ASS line breaks into newlines.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
        t = t.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, c) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] { t = t.replacingOccurrences(of: e, with: c) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func srt(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for block in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let ends = lines[i].components(separatedBy: "-->")
            guard ends.count == 2, let a = time(Substring(ends[0])),
                  let b = time(Substring(ends[1].split(separator: " ").first ?? "")) else { continue }
            let body = clean(lines[(i + 1)...].joined(separator: "\n"))
            if !body.isEmpty { cues.append(Cue(start: a, end: b, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func vtt(_ text: String) -> [Cue] {
        // Same cue layout as SRT once headers, NOTE/STYLE/REGION blocks and cue settings are ignored.
        srt(text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .filter { b in !["WEBVTT", "NOTE", "STYLE", "REGION"].contains { b.hasPrefix($0) } }
            .joined(separator: "\n\n"))
    }

    static func ass(_ text: String) -> [Cue] {
        var fields: [String] = ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
        var cues: [Cue] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Format:") && cues.isEmpty {
                fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("Dialogue:") {
                let v = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
                guard v.count == fields.count, let si = fields.firstIndex(of: "Start"), let ei = fields.firstIndex(of: "End"),
                      let ti = fields.firstIndex(of: "Text"), let a = time(v[si]), let b = time(v[ei]) else { continue }
                let body = clean(String(v[ti]))
                if !body.isEmpty { cues.append(Cue(start: a, end: b, text: body)) }
            }
        }
        return mergeOverlaps(cues.sorted { $0.start < $1.start })
    }

    /// Matroska text tracks: each block is one cue (S_TEXT/UTF8 = SRT text, S_TEXT/ASS = a Dialogue line without the timing).
    static func mkvTrack(_ mkv: MKVFile, _ t: MKVFile.Track) -> CaptionSource {
        let name = [t.name, Locale.current.localizedString(forLanguageCode: t.language) ?? t.language]
            .filter { !$0.isEmpty }.first ?? "Track \(t.number)"
        let kind = t.codecID.hasPrefix("S_TEXT") ? nil : t.codecID
        guard kind == nil else { return .unsupported(title: "\(name) (\(t.codecID == "S_HDMV/PGS" ? "image subtitles" : t.codecID))") }
        let ass = t.codecID.contains("ASS") || t.codecID.contains("SSA")
        var cues: [Cue] = []
        let pk = mkv.packets[t.number] ?? .init()
        for (i, p) in pk.enumerated() {
            let s = String(decoding: UnsafeBufferPointer(start: mkv.base + Int(p.offset), count: Int(p.size)), as: UTF8.self)
            var body = s
            if ass {
                // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
                let v = s.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                body = v.count == 9 ? String(v[8]) : s
            }
            body = clean(body)
            let start = mkv.seconds(p.pts)
            let end = p.duration > 0 ? mkv.seconds(p.pts + Int64(p.duration))
                                     : (i + 1 < pk.count ? mkv.seconds(pk[i + 1].pts) : start + 4)
            if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
        }
        return .cues(title: name, cues: mergeOverlaps(cues.sorted { $0.start < $1.start }))
    }

    /// Overlapping cues (common in ASS) are shown together.
    static func mergeOverlaps(_ cues: [Cue]) -> [Cue] { cues }
}

// MARK: - Rendering

/// Draws cue text over the video using the user's system caption style
/// (System Settings › Accessibility › Captions).
final class CaptionOverlay: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let backdrop = NSView()
    private var cues: [Cue] = []
    private var shown = ""
    private var textBackground: NSColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        backdrop.wantsLayer = true
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.isSelectable = false
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel("Caption")
        addSubview(backdrop)
        addSubview(label)
        isHidden = true
        applyStyle()
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged),
                                               name: kMACaptionAppearanceSettingsChangedNotification as NSNotification.Name, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steals clicks from the player

    func set(_ c: [Cue]) { cues = c; shown = "\u{0}"; isHidden = c.isEmpty }

    @objc private func styleChanged() { applyStyle(); shown = "\u{0}" }

    private var fontSize: CGFloat { max(13, bounds.height * 0.029) * MACaptionAppearanceGetRelativeCharacterSize(.user, nil) }

    private func applyStyle() {
        let fg = MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue()
        let fgA = MACaptionAppearanceGetForegroundOpacity(.user, nil)
        let bg = MACaptionAppearanceCopyBackgroundColor(.user, nil).takeRetainedValue()
        let bgA = MACaptionAppearanceGetBackgroundOpacity(.user, nil)
        let fd = MACaptionAppearanceCopyFontDescriptorForStyle(.user, nil, .default).takeRetainedValue()
        let font = CTFontCreateWithFontDescriptor(fd, fontSize, nil) as NSFont
        label.font = font
        label.textColor = NSColor(cgColor: fg)?.withAlphaComponent(fgA) ?? .white
        let edge = MACaptionAppearanceGetTextEdgeStyle(.user, nil)
        if edge == .dropShadow || edge == .raised || edge == .uniform || edge == .undefined {
            let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.9); sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1)
            label.shadow = sh
        } else { label.shadow = nil }
        // The system style has two backings: a box ("window") behind the whole caption, and a per-line
        // text background. Defaults are a 50% black box with no text background.
        let win = MACaptionAppearanceCopyWindowColor(.user, nil).takeRetainedValue()
        let winA = MACaptionAppearanceGetWindowOpacity(.user, nil)
        backdrop.layer?.backgroundColor = (NSColor(cgColor: win) ?? .black).withAlphaComponent(winA).cgColor
        backdrop.layer?.cornerRadius = MACaptionAppearanceGetWindowRoundedCornerRadius(.user, nil)
        textBackground = bgA > 0 ? (NSColor(cgColor: bg) ?? .black).withAlphaComponent(bgA) : nil
        needsLayout = true
    }

    /// Show the cue for `t` (seconds on the video's timeline).
    func update(time t: Double) {
        guard !cues.isEmpty else { return }
        var lo = 0, hi = cues.count
        while lo < hi { let m = (lo + hi) / 2; if cues[m].start <= t { lo = m + 1 } else { hi = m } }
        var active: [String] = []
        var i = lo - 1
        while i >= 0 && i >= lo - 8 { if cues[i].end > t { active.insert(cues[i].text, at: 0) }; i -= 1 }
        let text = active.joined(separator: "\n")
        guard text != shown else { return }
        shown = text
        if let tb = textBackground {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .backgroundColor: tb, .font: label.font as Any, .foregroundColor: label.textColor as Any,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
        } else {
            label.stringValue = text
        }
        label.isHidden = text.isEmpty
        backdrop.isHidden = text.isEmpty
        if !text.isEmpty { NSAccessibility.post(element: label, notification: .valueChanged) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.font = label.font.map { NSFont(descriptor: $0.fontDescriptor, size: fontSize) ?? $0 }
        let maxW = bounds.width * 0.84
        label.preferredMaxLayoutWidth = maxW
        let size = label.sizeThatFits(NSSize(width: maxW, height: .greatestFiniteMagnitude))
        let w = min(maxW, size.width), h = size.height
        // Sit above the control bar; captions stay readable whether controls are up or not.
        label.frame = NSRect(x: bounds.midX - w / 2, y: bounds.height * 0.08 + 18, width: w, height: h)
        backdrop.frame = label.frame.insetBy(dx: -12, dy: -6)
    }
}
