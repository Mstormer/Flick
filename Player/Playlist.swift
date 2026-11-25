import AppKit
import UniformTypeIdentifiers

/// The videos a window plays through: dropped or opened files, with folders expanded (recursively, in
/// Finder's name order).
enum Playlist {
    /// Containers Flick plays beyond what macOS declares as movies or audio (on a Mac without other players).
    static let extraExtensions: Set<String> = [
        "mkv", "mk3d", "mka", "webm", "wmv", "wma", "asf", "avi", "divx", "xvid", "vob", "mpg", "mpeg", "m1v", "m2v", "mpv",
        "ts", "m2t", "tp", "trp", "mts", "m2ts", "ogv", "ogg", "oga", "ogm", "opus", "spx", "flv", "f4v", "rm", "rmvb", "ra",
        "mxf", "nut", "ivf", "y4m", "wtv", "dv", "dif", "3gp", "3g2", "mjpg", "mjpeg", "h264", "264", "h265", "265", "hevc",
        "flac", "ape", "wv", "tta", "mpc", "tak", "dts", "dtshd", "ac3", "eac3", "thd", "mlp", "dsf", "w64", "voc", "amr",
        "shn", "xwma", "au", "snd", "caf", "aif", "aiff", "wav", "mp2", "mp3", "m4a", "aac"]

    /// Anything Flick opens: video, and sound on its own.
    static func isVideo(_ url: URL) -> Bool {
        if extraExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let t = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .audiovisualContent)
    }

    /// A regular file, or a symlink to one (resource values describe the link itself, so it is followed here;
    /// symlinked folders are still not entered, which keeps link loops out).
    private static func isFile(_ f: URL) -> Bool {
        guard let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        if v.isRegularFile == true { return true }
        guard v.isSymbolicLink == true else { return false }
        return (try? f.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Files as given (in the given order); each folder becomes its videos, sorted like Finder.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { out.append(u); continue }
            guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var found: [URL] = []
            for case let f as URL in e where isFile(f) && (isVideo(f) || isVideo(f.resolvingSymlinksInPath())) {
                found.append(f)
            }
            out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return out
    }
}

/// The list of videos (left side): one row each, the playing one selected. Clicking a row plays it; the
/// arrow keys stay with the player, so the list never takes keyboard focus.
final class PlaylistPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let effect = NSVisualEffectView()
    private let header = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = PlaylistTable()
    private var items: [URL] = []
    private var durations: [URL: Double] = [:]
    private var loading: Task<Void, Never>?
    private(set) var current = 0
    var onPick: ((Int) -> Void)?

    static let width: CGFloat = 300

    /// Tall enough for every row, up to the space available.
    func fittingHeight(_ available: CGFloat) -> CGFloat {
        min(available, 36 + CGFloat(items.count) * (table.rowHeight + table.intercellSpacing.height) + 8)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        addSubview(effect)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        addSubview(header)
        let col = NSTableColumn(identifier: .init("v"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.onClick = { [weak self] r in self?.clicked(r) }
        table.setAccessibilityLabel("Playlist")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { loading?.cancel() }

    func set(_ urls: [URL], current i: Int) {
        if urls != items {
            items = urls
            table.reloadData()
            loadDurations()
        }
        select(i)
    }

    func select(_ i: Int) {
        guard items.indices.contains(i) else { return }
        current = i
        header.stringValue = "\(i + 1) of \(items.count) videos"
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    /// Durations fill in as they're read, one file at a time in list order.
    private func loadDurations() {
        loading?.cancel()
        let list = items
        loading = Task { @MainActor [weak self] in
            for u in list where self?.durations[u] == nil {
                if Task.isCancelled { return }
                guard let d = await MediaInfo.duration(u) else { continue }
                guard let self else { return }
                self.durations[u] = d
                if let r = self.items.firstIndex(of: u) { self.table.reloadData(forRowIndexes: [r], columnIndexes: [0]) }
            }
        }
    }

    private func clicked(_ r: Int) {
        guard r >= 0 else { return }
        if r == current { select(r) } else { onPick?(r) }
    }

    func numberOfRows(in t: NSTableView) -> Int { items.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let cell = (t.makeView(withIdentifier: .init("row"), owner: nil) as? PlaylistRow) ?? PlaylistRow()
        cell.identifier = .init("row")
        let u = items[row]
        cell.name.stringValue = u.deletingPathExtension().lastPathComponent
        cell.time.stringValue = durations[u].map(ControlBar.fmt) ?? ""
        cell.setAccessibilityLabel(u.lastPathComponent + (durations[u].map { ", " + ControlBar.fmt($0) } ?? ""))
        return cell
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        header.frame = NSRect(x: 14, y: bounds.height - 26, width: bounds.width - 28, height: 16)
        scroll.frame = NSRect(x: 6, y: 6, width: bounds.width - 12, height: bounds.height - 36)
        table.tableColumns.first?.width = scroll.contentSize.width
    }
}

/// Rows play on a single click, also in a window that isn't frontmost, and the table never takes the
/// keyboard (the arrows belong to the player).
final class PlaylistTable: NSTableView {
    var onClick: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { onClick?(row(at: convert(e.locationInWindow, from: nil))) }
}

/// One row: the file name (middle-truncated, so episode numbers at the end stay visible) and its length.
final class PlaylistRow: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        addSubview(name); addSubview(time)
        textField = name
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let tw: CGFloat = 52
        time.frame = NSRect(x: bounds.width - tw - 8, y: (bounds.height - 15) / 2, width: tw, height: 15)
        name.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: bounds.width - tw - 20, height: 16)
    }
}

/// Where each video was left, so it opens there again. Keyed by path and size (a replaced file starts
/// over); the oldest entries go past 2,000. Playback › Clear Playback Cache forgets them all.
enum PlaybackMemory {
    private static let key = "positions"
    private static let limit = 2000

    private static func id(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return url.standardizedFileURL.path + "|\(size)"
    }

    private static var all: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// A place worth going back to: past the first few seconds and not at the very end.
    static func position(for url: URL, duration: Double) -> Double? {
        guard let t = all[id(url)]?.first, t > 3, duration <= 0 || t < duration - 5 else { return nil }
        return t
    }

    static func save(_ url: URL, at t: Double, duration: Double) {
        var d = all
        let k = id(url)
        if t <= 3 || (duration > 0 && t >= duration - 5) { d[k] = nil }       // finished, or barely started
        else { d[k] = [t, Date().timeIntervalSince1970] }
        if d.count > limit {
            for (k, _) in d.sorted(by: { ($0.value.last ?? 0) < ($1.value.last ?? 0) }).prefix(d.count - limit) { d[k] = nil }
        }
        all = d
    }

    static func forget(_ url: URL) { var d = all; d[id(url)] = nil; all = d }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
