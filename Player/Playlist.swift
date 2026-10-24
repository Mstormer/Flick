import AppKit
import UniformTypeIdentifiers

/// The videos a window plays through: dropped or opened files, with folders expanded (recursively, in
/// Finder's name order).
enum Playlist {
    /// Containers Flick plays beyond what macOS declares as movies.
    static let extraExtensions: Set<String> = ["mkv", "webm", "wmv", "asf", "vob", "mpg", "mpeg", "m2v", "mts", "m2ts"]

    static func isVideo(_ url: URL) -> Bool {
        if extraExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let t = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .movie) || t.conforms(to: .video)
    }

    /// Files as given (in the given order); each folder becomes its videos, sorted like Finder.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { out.append(u); continue }
            guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var found: [URL] = []
            for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true && isVideo(f) {
                found.append(f)
            }
            out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return out
    }
}

/// The list of videos (right side): one row each, the playing one selected. Clicking a row plays it; the
/// arrow keys stay with the player, so the list never takes keyboard focus.
final class PlaylistPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let effect = NSVisualEffectView()
    private let header = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = NSTableView()
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
        table.target = self
        table.action = #selector(clicked)
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

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0, r != current else { if r >= 0 { select(r) }; return }
        onPick?(r)
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
