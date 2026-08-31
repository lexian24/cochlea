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

    public var onQuit: (() -> Void)?
    public var onTogglePauseLearning: ((Bool) -> Void)?

    public init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(for: .idle)
        buildMenu()
    }

    public func update(state: DictationController.State) {
        configureButton(for: state)
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

        let status = NSMenuItem(title: "No model installed", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

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

    @objc private func quit() {
        onQuit?()
    }
}
