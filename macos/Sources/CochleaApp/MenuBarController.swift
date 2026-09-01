import AppKit
import CochleaCore
import Foundation

/// The menu bar presence M0 requires.
///
/// It also carries the "pause learning" toggle, which SPEC §7 raises as a
/// possible M1 stopgap for P3 — someone else using the machine — while speaker
/// verification waits for M5. It is inert until there is learning to pause,
/// but the control belongs where a non-technical second user can find it, and
/// that is not the CLI.
@MainActor
public final class MenuBarController {

    private let statusItem: NSStatusItem
    private var learningPaused = false
    /// The two lines at the top of the menu. They used to be one static
    /// "No model installed", which was wrong as soon as a model was installed
    /// and useless while testing the runtime behaviour M0 has not verified —
    /// the menu is the only surface a menu bar app has, so it is where the
    /// answer to "what just happened?" belongs.
    private let backendItem = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
    private let eventItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let shortcutItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    public var onQuit: (() -> Void)?
    public var onTogglePauseLearning: ((Bool) -> Void)?
    public var onOpenSettings: (() -> Void)?

    public init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(for: .idle)
        buildMenu()
    }

    public func update(state: DictationController.State) {
        configureButton(for: state)
    }

    /// What the app is wired up to: the transcriber and the model behind it.
    public func describeBackend(_ description: String) {
        backendItem.title = description
    }

    /// The shortcut and how it behaves, so the menu answers "what do I press?"
    /// without opening Settings.
    public func describeShortcut(_ shortcut: String, activation: String) {
        let how: String
        switch activation {
        case "holdToTalk": how = "hold"
        case "toggle":     how = "press, then press again"
        default:           how = "hold, or tap to keep listening"
        }
        shortcutItem.title = "Dictate: \(shortcut) — \(how)"
    }

    /// The last thing that happened, so a failure is readable without a log.
    public func describeEvent(_ description: String) {
        eventItem.title = description.count > 70
            ? String(description.prefix(69)) + "…"
            : description
        eventItem.toolTip = description
    }

    private func configureButton(for state: DictationController.State) {
        guard let button = statusItem.button else { return }
        let (symbol, description): (String, String) = {
            switch state {
            case .idle:         return ("mic", "cochlea: ready")
            case .listening:    return ("mic.fill", "cochlea: listening")
            case .transcribing: return ("waveform", "cochlea: transcribing")
            case .failed:       return ("exclamationmark.triangle", "cochlea: error")
            }
        }()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.toolTip = description
        if case .failed(let message) = state { button.toolTip = "cochlea: \(message)" }
    }

    private func buildMenu() {
        let menu = NSMenu()

        backendItem.isEnabled = false
        eventItem.isEnabled = false
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        menu.addItem(backendItem)
        menu.addItem(eventItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let pause = NSMenuItem(title: "Pause learning",
                               action: #selector(togglePauseLearning),
                               keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit cochlea", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func togglePauseLearning(_ sender: NSMenuItem) {
        learningPaused.toggle()
        sender.state = learningPaused ? .on : .off
        onTogglePauseLearning?(learningPaused)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
