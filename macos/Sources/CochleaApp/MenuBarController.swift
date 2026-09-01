import AppKit
import CochleaCore
import Foundation

/// The menu bar presence M0 requires, and the whole of the app's interface
/// until someone opens Settings.
///
/// Laid out as three groups rather than a flat list, because the questions it
/// answers are different in kind: **what is it doing right now**, **what do I
/// press**, and **what can I change**. A flat list of disabled text made the
/// first two indistinguishable from each other and from the third.
///
/// It also carries the "pause learning" toggle, which SPEC §7 raises as a
/// possible M1 stopgap for P3 — someone else using the machine — while speaker
/// verification waits for M5.
@MainActor
public final class MenuBarController {

    private let statusItem: NSStatusItem
    private var learningPaused = false

    /// The status line: what the app is doing, in the app's own voice.
    private let statusItemRow = NSMenuItem()
    /// What the two shortcuts are, so the menu answers "what do I press?"
    /// without opening Settings.
    private let shortcutItem = NSMenuItem()
    private let fixItem = NSMenuItem()
    /// The model behind it, and how output reaches the cursor.
    private let backendItem = NSMenuItem()
    /// The last thing that happened, so a failure is readable without a log.
    private let eventItem = NSMenuItem()

    public var onQuit: (() -> Void)?
    public var onTogglePauseLearning: ((Bool) -> Void)?
    public var onOpenSettings: (() -> Void)?
    /// Jump straight to the pane where a lexicon is imported and reviewed.
    /// The icon is the only entry point this app has, so anything a user is
    /// meant to do has to be reachable from it in one click.
    public var onTeachWords: (() -> Void)?

    public init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(for: .idle)
        buildMenu()
        update(state: .idle)
    }

    public func update(state: DictationController.State) {
        configureButton(for: state)
        let (symbol, text, tint): (String, String, NSColor) = {
            switch state {
            case .idle:
                return ("circle.fill", "Ready", .systemGreen)
            case .listening:
                return ("waveform", "Listening…", .systemRed)
            case .transcribing:
                return ("ellipsis", "Working…", .systemOrange)
            case .failed(let message):
                return ("exclamationmark.triangle.fill", message, .systemRed)
            }
        }()
        statusItemRow.attributedTitle = Self.row(
            text, symbol: symbol, tint: tint, emphasis: true)
    }

    /// What the app is wired up to: the model, and where text appears.
    public func describeBackend(_ description: String) {
        backendItem.attributedTitle = Self.row(description, symbol: "cpu")
    }

    /// The shortcuts, and how the dictation one behaves.
    public func describeShortcut(_ shortcut: String, activation: String,
                                 fix: String? = nil) {
        let how: String
        switch activation {
        case "holdToTalk": how = "hold to talk"
        case "toggle":     how = "press to start, press to stop"
        default:           how = "hold, or tap to keep listening"
        }
        shortcutItem.attributedTitle = Self.shortcutRow(
            "Dictate", key: shortcut, detail: how)
        if let fix {
            fixItem.attributedTitle = Self.shortcutRow(
                "Fix the last one", key: fix, detail: nil)
        }
    }

    /// The last thing that happened. Truncated, with the whole of it in the
    /// tooltip — an error long enough to matter is longer than a menu is wide.
    public func describeEvent(_ description: String) {
        let shown = description.count > 60
            ? String(description.prefix(59)) + "…"
            : description
        eventItem.attributedTitle = Self.row(shown, symbol: "clock.arrow.circlepath")
        eventItem.toolTip = description
    }

    // MARK: - the status item

    private func configureButton(for state: DictationController.State) {
        guard let button = statusItem.button else { return }
        let description: String = {
            switch state {
            case .idle:         return "cochlea: ready"
            case .listening:    return "cochlea: listening"
            case .transcribing: return "cochlea: transcribing"
            case .failed:       return "cochlea: error"
            }
        }()
        // The mark, not an SF Symbol. A microphone glyph is the one a dozen
        // other apps use, so the bar gave no way to tell which icon was this
        // app — and for a menu bar app the icon *is* the identity, because it
        // is the whole of the interface until you click it.
        let image = MenuBarIcon.image(for: state)
        image.accessibilityDescription = description
        button.image = image
        button.toolTip = description
        if case .failed(let message) = state { button.toolTip = "cochlea: \(message)" }
    }

    // MARK: - the menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for item in [statusItemRow, shortcutItem, fixItem, backendItem, eventItem] {
            item.isEnabled = false
        }

        menu.addItem(header("Status"))
        menu.addItem(statusItemRow)
        menu.addItem(eventItem)

        menu.addItem(header("Shortcuts"))
        menu.addItem(shortcutItem)
        menu.addItem(fixItem)

        menu.addItem(header("Model"))
        menu.addItem(backendItem)

        menu.addItem(.separator())
        menu.addItem(action("Teach it your words…", symbol: "text.book.closed",
                            selector: #selector(teachWords), key: ""))
        menu.addItem(action("Settings…", symbol: "gearshape",
                            selector: #selector(openSettings), key: ","))
        menu.addItem(action("Pause learning", symbol: "pause.circle",
                            selector: #selector(togglePauseLearning), key: ""))
        menu.addItem(.separator())
        menu.addItem(action("Quit cochlea", symbol: "power",
                            selector: #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func header(_ title: String) -> NSMenuItem {
        // `sectionHeader` gives the system's own header treatment rather than
        // an imitation of it, which is the difference between looking like a
        // Mac menu and looking like a menu drawn by an app.
        //
        // It arrived in macOS 14 and the package still builds for 13 (the
        // shipped Info.plist asks for 14; the disagreement predates this and
        // resolving it is a support decision, not a layout one). The fallback
        // is the pattern that treatment replaced.
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem()
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        return item
    }

    private func action(_ title: String, symbol: String,
                        selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    // MARK: - rows
    //
    // Attributed rather than plain, because a disabled `NSMenuItem` renders
    // its title in the system's disabled grey — which is right for a control
    // nobody can click and wrong for the line telling you the microphone is
    // open. Setting `attributedTitle` opts out of that.

    private static func row(_ text: String, symbol: String,
                            tint: NSColor = .secondaryLabelColor,
                            emphasis: Bool = false) -> NSAttributedString {
        let line = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let attachment = NSTextAttachment()
            let configuration = NSImage.SymbolConfiguration(
                pointSize: 10, weight: emphasis ? .semibold : .regular)
            attachment.image = image.withSymbolConfiguration(configuration)?
                .tinted(tint)
            attachment.bounds = CGRect(x: 0, y: -1.5, width: 12, height: 12)
            line.append(NSAttributedString(attachment: attachment))
            line.append(NSAttributedString(string: "  "))
        }
        line.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.systemFontSize(for: .small)),
            .foregroundColor: emphasis ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]))
        return line
    }

    /// A shortcut row: what it does on the left, the keys on the right.
    private static func shortcutRow(_ title: String, key: String,
                                    detail: String?) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize(for: .small))
        let line = NSMutableAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        line.append(NSAttributedString(string: "   " + key, attributes: [
            // Monospaced, so ⌃⌥D and ⌃⌥F line up under one another and read as
            // keys rather than as prose.
            .font: NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize(for: .small), weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        if let detail {
            line.append(NSAttributedString(string: "  ·  " + detail, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return line
    }

    @objc private func togglePauseLearning(_ sender: NSMenuItem) {
        learningPaused.toggle()
        sender.state = learningPaused ? .on : .off
        sender.image = NSImage(
            systemSymbolName: learningPaused ? "play.circle" : "pause.circle",
            accessibilityDescription: nil)
        sender.title = learningPaused ? "Resume learning" : "Pause learning"
        onTogglePauseLearning?(learningPaused)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func teachWords() {
        onTeachWords?()
    }

    @objc private func quit() {
        onQuit?()
    }
}

private extension NSImage {
    /// A copy of this symbol in one colour.
    ///
    /// The status dot has to be green, red or orange to carry its meaning at a
    /// glance, and a template symbol in a menu is drawn in the label colour
    /// whatever it was configured with.
    func tinted(_ color: NSColor) -> NSImage {
        let copy = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill(using: .sourceOver)
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        copy.isTemplate = false
        return copy
    }
}
