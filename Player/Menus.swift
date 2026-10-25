import AppKit

/// Menu bar, following the HIG order: Flick, File, Edit-less (no text editing), View, Playback, Window, Help.
/// Every player command lives here, so each one has a visible shortcut and works with Full Keyboard Access.
/// Player actions are sent to the first responder (the key PlayerView); items disable themselves when no
/// player window is key, so single-key shortcuts never fire while typing in Settings.
enum MainMenu {
    static let shortcutsTag = 900          // items generated from the Settings shortcut table
    static let previousVideoTag = 801, nextVideoTag = 802, volumeUpTag = 803, volumeDownTag = 804
    static func key(_ scalar: Int) -> String { String(Character(UnicodeScalar(scalar)!)) }

    static func build(_ app: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // Flick
        let appMenu = submenu(main, "Flick")
        appMenu.addItem(withTitle: "About Flick", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",").target = app
        appMenu.addItem(.separator())
        let services = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services"); NSApp.servicesMenu = services.submenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Flick", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.option, .command])
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Flick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let file = submenu(main, "File")
        file.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o").target = app
        let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = app
        recentItem.submenu = recent
        item(file, "Open Most Recent", #selector(AppDelegate.openMostRecent(_:)), "r", [.option]).target = app
        file.addItem(.separator())
        item(file, "Add Subtitle File…", #selector(PlayerView.addSubtitleFile(_:)), "o", [.shift, .command])
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // View
        let view = submenu(main, "View")
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command])
        view.addItem(.separator())
        item(view, "Hide Controls", #selector(PlayerView.toggleControllerVisibility(_:)), "", [])
        item(view, "Show Playlist", #selector(PlayerView.togglePlaylist(_:)), "\\", [])
        item(view, "Show Info", #selector(PlayerView.toggleInfo(_:)), "i", [])
        let subsItem = view.addItem(withTitle: "Subtitles", action: nil, keyEquivalent: "")
        let subs = NSMenu(title: "Subtitles")
        subs.delegate = app
        subsItem.submenu = subs

        // Playback (app-specific: between View and Window)
        let pb = submenu(main, "Playback")
        item(pb, "Play", #selector(PlayerView.togglePlay), " ", [])
        pb.addItem(.separator())
        let left = key(NSLeftArrowFunctionKey), right = key(NSRightArrowFunctionKey)
        for (title, k, mods, by) in [("Skip Forward 5 Seconds", right, NSEvent.ModifierFlags(), 5.0),
                                     ("Skip Back 5 Seconds", left, [], -5),
                                     ("Skip Forward 1 Second", right, [.shift], 1),
                                     ("Skip Back 1 Second", left, [.shift], -1),
                                     ("Skip Forward 30 Seconds", right, [.option], 30),
                                     ("Skip Back 30 Seconds", left, [.option], -30),
                                     ("Skip Forward 10 Minutes", key(NSPageUpFunctionKey), [.shift], 600),
                                     ("Skip Back 10 Minutes", key(NSPageDownFunctionKey), [.shift], -600)] {
            item(pb, title, #selector(PlayerView.menuSkip(_:)), k, mods).representedObject = by
        }
        item(pb, "Next Frame", #selector(PlayerView.nextFrame(_:)), ".", [])
        item(pb, "Previous Frame", #selector(PlayerView.previousFrame(_:)), ",", [])
        pb.addItem(.separator())
        let speedItem = pb.addItem(withTitle: "Speed", action: nil, keyEquivalent: "")
        let speed = NSMenu(title: "Speed")
        speedItem.submenu = speed
        item(speed, "Faster", #selector(PlayerView.faster), "]", [])
        item(speed, "Slower", #selector(PlayerView.slower), "[", [])
        item(speed, "Normal Speed", #selector(PlayerView.normalSpeed), "\u{7f}", [])
        speed.addItem(.separator())
        for r in 1...4 { item(speed, "\(r)×", #selector(PlayerView.setSpeedFromMenu(_:)), "\(r)", []).tag = r }
        pb.addItem(.separator())
        item(pb, "Previous Video", #selector(PlayerView.previousVideo(_:)), "", []).tag = previousVideoTag
        item(pb, "Next Video", #selector(PlayerView.nextVideo(_:)), "", []).tag = nextVideoTag
        pb.addItem(.separator())
        item(pb, "Volume Up", #selector(PlayerView.volumeUp(_:)), key(NSUpArrowFunctionKey), []).tag = volumeUpTag
        item(pb, "Volume Down", #selector(PlayerView.volumeDown(_:)), key(NSDownArrowFunctionKey), []).tag = volumeDownTag
        item(pb, "Mute", #selector(PlayerView.toggleMute(_:)), "m", [])
        pb.addItem(.separator())
        pb.addItem(withTitle: "Clear Playback Cache", action: #selector(AppDelegate.clearPlaybackCache(_:)), keyEquivalent: "").target = app
        pb.addItem(.separator())
        let custom = pb.addItem(withTitle: "Your Shortcuts", action: nil, keyEquivalent: "")
        custom.isEnabled = false
        custom.tag = shortcutsTag - 1
        refreshShortcuts(pb)
        NotificationCenter.default.addObserver(forName: Shortcuts.changed, object: nil, queue: .main) { _ in refreshShortcuts(pb) }

        // Window
        let win = submenu(main, "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        win.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win

        // Help
        let help = submenu(main, "Help")
        help.addItem(withTitle: "Flick Help", action: #selector(AppDelegate.showHelp(_:)), keyEquivalent: "?").target = app
        help.addItem(.separator())
        help.addItem(withTitle: "Open-Source Licenses", action: #selector(AppDelegate.showLicenses(_:)), keyEquivalent: "").target = app
        NSApp.helpMenu = help
        return main
    }

    /// With the playlist showing, ↑/↓ are Previous/Next Video and volume is ⌥↑/⌥↓; with it hidden it's the
    /// other way round; a single video has ↑/↓ for volume only. Set whenever this changes or a player window
    /// becomes key, so the menu always shows the live keys.
    static func setPlaylistMode(_ playlist: Bool, visible: Bool) {
        guard let pb = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Playback" })?.submenu else { return }
        let up = key(NSUpArrowFunctionKey), down = key(NSDownArrowFunctionKey)
        let switchMods: NSEvent.ModifierFlags = visible ? [] : [.option]
        for (tag, k) in [(previousVideoTag, up), (nextVideoTag, down)] {
            guard let i = pb.item(withTag: tag) else { continue }
            i.keyEquivalent = playlist ? k : ""
            i.keyEquivalentModifierMask = switchMods
        }
        for (tag, k) in [(volumeUpTag, up), (volumeDownTag, down)] {
            guard let i = pb.item(withTag: tag) else { continue }
            i.keyEquivalent = k
            i.keyEquivalentModifierMask = playlist && visible ? [.option] : []
        }
    }

    /// The Settings shortcut table, shown as real menu items so its keys are discoverable and searchable.
    static func refreshShortcuts(_ pb: NSMenu) {
        for i in pb.items where i.tag == shortcutsTag { pb.removeItem(i) }
        for (n, s) in Shortcuts.shared.items.enumerated() where !s.key.isEmpty {
            let title: String
            switch s.action {
            case .slower: title = String(format: "Decrease Speed by %g×", s.value)
            case .faster: title = String(format: "Increase Speed by %g×", s.value)
            case .rewind: title = String(format: "Rewind %g Seconds", s.value)
            case .advance: title = String(format: "Advance %g Seconds", s.value)
            case .preferredSpeed: title = String(format: "Preferred Speed (%g×)", s.value)
            case .resetSpeed: title = "Reset Speed"
            case .toggleController: title = "Show/Hide Controls"
            case .toggleSubtitles: title = "Show/Hide Subtitles"
            case .playPause: title = "Play/Pause"
            case .mute: title = "Mute/Unmute"
            }
            let i = NSMenuItem(title: title, action: #selector(PlayerView.performShortcutItem(_:)), keyEquivalent: s.key)
            i.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: s.modifiers)
            i.representedObject = n
            i.tag = shortcutsTag
            i.indentationLevel = 1
            pb.addItem(i)
        }
    }

    @discardableResult
    private static func item(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let i = m.addItem(withTitle: title, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let host = NSMenuItem(); main.addItem(host)
        let m = NSMenu(title: title)
        host.submenu = m
        return m
    }
}

// MARK: - Open Recent, Subtitles (dynamic menus), Help

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == "Open Recent" {
            let urls = NSDocumentController.shared.recentDocumentURLs
            if urls.isEmpty {
                let none = menu.addItem(withTitle: "No Recent Videos", action: nil, keyEquivalent: "")
                none.isEnabled = false
                return
            }
            for u in urls {
                let i = menu.addItem(withTitle: u.lastPathComponent, action: #selector(openRecentItem(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = u
                let icon = NSWorkspace.shared.icon(forFile: u.path)
                icon.size = NSSize(width: 16, height: 16)
                i.image = icon
                i.toolTip = u.path
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecents(_:)), keyEquivalent: "").target = self
        } else if menu.title == "Subtitles" {
            guard let view = (NSApp.mainWindow?.contentView as? PlayerView) else {
                menu.addItem(withTitle: "No Video Open", action: nil, keyEquivalent: "").isEnabled = false
                return
            }
            view.fillSubtitlesMenu(menu)
        }
    }

    @objc func openRecentItem(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { open(u) }
    }

    @objc func clearRecents(_ s: Any?) { NSDocumentController.shared.clearRecentDocuments(s) }

    /// ⌥R: the most recently opened video that isn't already on screen (or the newest one, if all are).
    @objc func openMostRecent(_ s: Any?) {
        let urls = NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        let openPaths = Set(windows.map { $0.url.standardizedFileURL.path })
        guard let u = urls.first(where: { !openPaths.contains($0.standardizedFileURL.path) }) ?? urls.first else { NSSound.beep(); return }
        open(u)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openMostRecent(_:)) { return !NSDocumentController.shared.recentDocumentURLs.isEmpty }
        return true
    }

    @objc func showHelp(_ s: Any?) { HelpWindow.shared.show() }
    @objc func showLicenses(_ s: Any?) {
        if let u = HelpWindow.licenses { NSWorkspace.shared.open(u) }
    }
}

/// A plain list of every shortcut, generated from the menu bar so it can't drift out of date.
final class HelpWindow: NSWindowController {
    static let shared = HelpWindow()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Flick Help"
        super.init(window: w)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The LGPL notice and full license text, in the app's Resources.
    static var licenses: URL? { Bundle.main.url(forResource: "Licenses", withExtension: "txt") }

    func show() {
        let text = NSMutableAttributedString()
        let h = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]
        let b = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 13)]
        let k = [NSAttributedString.Key.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        func walk(_ m: NSMenu) {
            for i in m.items {
                if let s = i.submenu, !["Services", "Open Recent", "Subtitles"].contains(s.title) { walk(s); continue }
                guard !i.keyEquivalent.isEmpty, i.action != nil else { continue }
                text.append(NSAttributedString(string: i.title + "\t", attributes: b))
                text.append(NSAttributedString(string: label(i) + "\n", attributes: k))
            }
        }
        for top in NSApp.mainMenu?.items ?? [] where top.submenu != nil {
            let start = text.length
            walk(top.submenu!)
            if text.length > start {
                text.insert(NSAttributedString(string: "\n" + (top.submenu!.title) + "\n", attributes: h), at: start)
            }
        }
        text.append(NSAttributedString(string: "\nGestures\n", attributes: h))
        text.append(NSAttributedString(string: "Swipe left or right with two fingers\t", attributes: b))
        text.append(NSAttributedString(string: "Seek (right goes forward)\n", attributes: k))
        text.append(NSAttributedString(string: "Swipe up or down with two fingers\t", attributes: b))
        text.append(NSAttributedString(string: "Volume (up is louder)\n", attributes: k))
        text.append(NSAttributedString(string: "Double-click the video\t", attributes: b))
        text.append(NSAttributedString(string: "Full screen\n", attributes: k))
        text.append(NSAttributedString(string: "Pinch in or spread out\t", attributes: b))
        text.append(NSAttributedString(string: "Window size\n", attributes: k))
        text.append(NSAttributedString(string: "Drop files or a folder on the window\t", attributes: b))
        text.append(NSAttributedString(string: "Playlist\n", attributes: k))
        text.append(NSAttributedString(string: "\nPlaylists\n", attributes: h))
        text.append(NSAttributedString(string: "Open or drop several videos, or a folder (searched with its subfolders), to play them in one window. "
            + "\\ shows or hides the list. While it shows, ↑ and ↓ move through it and ⌥↑ ⌥↓ set the volume; while it's hidden, ↑ ↓ are volume and ⌥↑ ⌥↓ switch videos. While playing, the list fades with the controls. The next video starts when one ends. While paused, switching shows only the name until you press Play.\n", attributes: b))

        text.append(NSAttributedString(string: "\nOpen-Source Software\n", attributes: h))
        text.append(NSAttributedString(string: "WMV, VC-1, WMA, DTS, TrueHD, Vorbis and some VP9 files are decoded with libavformat, "
            + "libavcodec and libavutil from the FFmpeg project (version 9.0.2, unmodified), licensed under the GNU Lesser "
            + "General Public License version 2.1 or later. They are separate libraries inside Flick.app/Contents/Frameworks "
            + "and can be replaced with your own build. ", attributes: b))
        var link: [NSAttributedString.Key: Any] = b
        if let u = Self.licenses { link[.link] = u }
        text.append(NSAttributedString(string: "License text and source", attributes: link))
        text.append(NSAttributedString(string: "\n", attributes: b))
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 400)]
        para.paragraphSpacing = 3
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))

        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.textContainerInset = NSSize(width: 16, height: 12)
        tv.textStorage?.setAttributedString(text)
        tv.textColor = nil
        window?.contentView = scroll
        showWindow(nil)
    }

    /// "⌃⌥⇧⌘" order, as the HIG lists modifiers.
    private func label(_ i: NSMenuItem) -> String {
        var s = ""
        let f = i.keyEquivalentModifierMask
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let names: [String: String] = [" ": "Space", MainMenu.key(NSLeftArrowFunctionKey): "←", MainMenu.key(NSRightArrowFunctionKey): "→",
                                       MainMenu.key(NSUpArrowFunctionKey): "↑", MainMenu.key(NSDownArrowFunctionKey): "↓",
                                       MainMenu.key(NSPageUpFunctionKey): "Page Up", MainMenu.key(NSPageDownFunctionKey): "Page Down"]
        let key = i.keyEquivalent
        return s + (names[key] ?? (key == key.uppercased() && key != key.lowercased() ? "⇧" + key : key.uppercased()))
    }
}
