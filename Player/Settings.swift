import AppKit

// MARK: - Shortcut model

enum ShortcutAction: String, CaseIterable, Codable {
    case toggleController, slower, faster, rewind, advance, resetSpeed, preferredSpeed, playPause, mute, toggleSubtitles

    var title: String {
        switch self {
        case .toggleController: return "Show/hide controller"
        case .slower: return "Decrease speed"
        case .faster: return "Increase speed"
        case .rewind: return "Rewind"
        case .advance: return "Advance"
        case .resetSpeed: return "Reset speed"
        case .preferredSpeed: return "Preferred speed"
        case .playPause: return "Play/pause"
        case .mute: return "Mute"
        case .toggleSubtitles: return "Show/hide subtitles"
        }
    }

    /// Whether the value column means something for this action (greyed out otherwise).
    var takesValue: Bool { ![.toggleController, .resetSpeed, .playPause, .mute, .toggleSubtitles].contains(self) }

    /// Value shown for actions that don't take one, and the starting value for those that do.
    var defaultValue: Double {
        switch self {
        case .slower: return 0.1
        case .faster: return 0.2
        case .rewind, .advance: return 10
        case .resetSpeed: return 1
        case .preferredSpeed: return 2
        default: return 0
        }
    }

    var unit: String {
        switch self {
        case .rewind, .advance: return "s"
        case .slower, .faster, .preferredSpeed, .resetSpeed: return "×"
        default: return ""
        }
    }
}

struct Shortcut: Codable, Equatable {
    var action: ShortcutAction
    var key: String          // charactersIgnoringModifiers, lowercased; "" = unassigned
    var modifiers: UInt      // device-independent flags (⌘ ⌥ ⌃ ⇧)
    var value: Double

    static let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var label: String {
        guard !key.isEmpty else { return "" }
        let f = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let names = [" ": "Space", "\u{7f}": "⌫", "\r": "↩", "\t": "⇥",
                     "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→"]
        return s + (names[key] ?? key.uppercased())
    }
}

/// The user's shortcut table, saved in UserDefaults. Defaults follow the Video Speed Controller layout.
final class Shortcuts {
    static let shared = Shortcuts()
    static let changed = Notification.Name("FlickShortcutsChanged")

    static let defaults: [Shortcut] = [
        Shortcut(action: .toggleController, key: "v", modifiers: 0, value: 0),
        Shortcut(action: .slower, key: "a", modifiers: 0, value: 0.1),
        Shortcut(action: .faster, key: "s", modifiers: 0, value: 0.2),
        Shortcut(action: .rewind, key: "z", modifiers: 0, value: 10),
        Shortcut(action: .advance, key: "x", modifiers: 0, value: 10),
        Shortcut(action: .resetSpeed, key: "d", modifiers: 0, value: 1),
        Shortcut(action: .preferredSpeed, key: "r", modifiers: 0, value: 2),
    ]

    var items: [Shortcut] {
        didSet {
            if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "shortcuts") }
            NotificationCenter.default.post(name: Shortcuts.changed, object: nil)
        }
    }

    private init() {
        if let d = UserDefaults.standard.data(forKey: "shortcuts"), let s = try? JSONDecoder().decode([Shortcut].self, from: d) {
            items = s
        } else {
            items = Shortcuts.defaults
        }
    }

    func match(_ e: NSEvent) -> Shortcut? {
        guard let k = e.charactersIgnoringModifiers?.lowercased(), !k.isEmpty else { return nil }
        let m = e.modifierFlags.intersection(Shortcut.relevantFlags).rawValue
        // A shifted letter arrives as its uppercase form; compare lowercased with shift kept in the flags.
        return items.first { $0.key == k && $0.modifiers == m }
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private let list = NSStackView()

    private init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Flick Settings"
        super.init(window: win)
        win.contentView = buildContent()
        win.center()
        win.initialFirstResponder = nil
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Shortcuts")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "Click a key box, then press the key (with modifiers if you like). Esc cancels, ⌫ clears it.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8

        let add = NSButton(title: "Add Shortcut", target: self, action: #selector(addRow))
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        let buttons = NSStackView(views: [add, restore])
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, hint, list, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            hint.widthAnchor.constraint(equalToConstant: 480),
        ])
        return root
    }

    func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, s) in Shortcuts.shared.items.enumerated() {
            list.addArrangedSubview(ShortcutRow(index: i, shortcut: s) { [weak self] in self?.reload() })
        }
        if let w = window, let c = w.contentView {
            c.layoutSubtreeIfNeeded()
            let h = c.fittingSize.height
            var f = w.frame
            let newH = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 520, height: max(200, h))).height
            f.origin.y += f.height - newH
            f.size = NSSize(width: f.width, height: newH)
            w.setFrame(f, display: true)
        }
    }

    @objc private func addRow() {
        Shortcuts.shared.items.append(Shortcut(action: .advance, key: "", modifiers: 0, value: ShortcutAction.advance.defaultValue))
        reload()
    }

    @objc private func restoreDefaults() {
        Shortcuts.shared.items = Shortcuts.defaults
        reload()
    }
}

private final class ShortcutRow: NSStackView {
    private let index: Int
    private let onChange: () -> Void
    private let actionPopup = NSPopUpButton()
    private let keyField: KeyRecorder
    private let valueField = NSTextField()
    private let remove = NSButton()

    init(index: Int, shortcut: Shortcut, onChange: @escaping () -> Void) {
        self.index = index
        self.onChange = onChange
        keyField = KeyRecorder(shortcut: shortcut)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8

        for a in ShortcutAction.allCases { actionPopup.addItem(withTitle: a.title) }
        actionPopup.selectItem(at: ShortcutAction.allCases.firstIndex(of: shortcut.action) ?? 0)
        actionPopup.target = self; actionPopup.action = #selector(actionChanged)

        keyField.onRecord = { [weak self] key, mods in
            guard let self else { return }
            var items = Shortcuts.shared.items
            // one key, one action: taking a key moves it off any other row
            for i in items.indices where i != self.index && items[i].key == key && items[i].modifiers == mods && !key.isEmpty {
                items[i].key = ""
            }
            items[self.index].key = key
            items[self.index].modifiers = mods
            Shortcuts.shared.items = items
            self.onChange()
        }

        valueField.alignment = .center
        valueField.formatter = {
            let f = NumberFormatter()
            f.minimum = 0; f.maximum = 3600; f.maximumFractionDigits = 2; f.numberStyle = .decimal
            return f
        }()
        valueField.target = self; valueField.action = #selector(valueChanged)
        valueField.delegate = self
        setValueField(shortcut)

        remove.isBordered = false
        remove.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove shortcut")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = "Remove this shortcut"
        remove.target = self; remove.action = #selector(removeRow)

        for v in [actionPopup, keyField, valueField, remove] { addArrangedSubview(v) }
        actionPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        keyField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        valueField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        remove.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setValueField(_ s: Shortcut) {
        valueField.doubleValue = s.action.takesValue ? s.value : s.action.defaultValue
        valueField.isEnabled = s.action.takesValue
        valueField.toolTip = s.action.unit == "s" ? "Seconds" : s.action.unit == "×" ? "Playback speed" : nil
    }

    @objc private func actionChanged() {
        let a = ShortcutAction.allCases[actionPopup.indexOfSelectedItem]
        Shortcuts.shared.items[index].action = a
        Shortcuts.shared.items[index].value = a.defaultValue
        setValueField(Shortcuts.shared.items[index])
    }

    @objc private func valueChanged() {
        guard Shortcuts.shared.items[index].action.takesValue else { return }
        Shortcuts.shared.items[index].value = max(0.01, valueField.doubleValue)
    }

    @objc private func removeRow() {
        Shortcuts.shared.items.remove(at: index)
        onChange()
    }
}

extension ShortcutRow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) { valueChanged() }
}

/// A key box: click, then press the key combination to assign it.
private final class KeyRecorder: NSButton {
    var onRecord: ((String, UInt) -> Void)?
    private var monitor: Any?
    private let shortcut: Shortcut

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        title = shortcut.label.isEmpty ? "—" : shortcut.label
        target = self; action = #selector(startRecording)
        setAccessibilityLabel("Shortcut key")
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func startRecording() {
        title = "Press a key…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            self.stop()
            if e.keyCode == 53 { self.title = self.shortcut.label.isEmpty ? "—" : self.shortcut.label; return nil }   // Esc
            if e.keyCode == 51 { self.onRecord?("", 0); return nil }                                                  // ⌫ clears
            let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
            let mods = e.modifierFlags.intersection(Shortcut.relevantFlags).rawValue
            self.onRecord?(key, mods)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { stop() }
}
