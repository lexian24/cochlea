import AppKit
import CochleaASR
import CochleaCore
import Foundation

/// M0's entry point.
///
/// The app is an accessory: it lives in the menu bar and never takes a Dock
/// icon or a window, because dictation happens inside whatever application the
/// user is already in.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Defaults, unless `~/.cochlea/config.json` says otherwise.
    ///
    /// `Configuration.save()` and `load(from:)` both existed and nothing
    /// called the loader, so the file the app writes was never read back. That
    /// also made `modelIdentifier` unchangeable without a rebuild, which
    /// matters directly: D6 measured `whisper-small` inside M0's latency
    /// budget and the default `large-v3-turbo` outside it on an 8 GB machine.
    private var configuration = AppDelegate.loadConfiguration()

    static func loadConfiguration() -> Configuration {
        let defaults = Configuration()
        guard FileManager.default.fileExists(atPath: defaults.configFile.path) else {
            return defaults
        }
        do {
            let loaded = try Configuration.load(from: defaults.configFile)
            Diagnostics.log("config", "loaded \(defaults.configFile.path)")
            return loaded
        } catch {
            // A corrupt config must not stop the app starting; defaults are
            // always usable and the reason is logged.
            Diagnostics.log("config", "ignoring \(defaults.configFile.path): \(error)")
            return defaults
        }
    }
    private var menuBar: MenuBarController?
    private var controller: DictationController?
    private var settings: SettingsWindowController?
    private var correction: CorrectionPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            try configuration.ensureHomeExists()
        } catch {
            presentFatal("Could not create \(configuration.home.path): \(error)")
            return
        }

        // ASR runs in a Python helper (docs/DECISIONS.md D5). If the helper
        // or the model is missing this returns a transcriber that refuses with
        // the reason — the app still runs, because typing invented words at
        // the user's cursor would be worse than typing nothing.
        let transcriber: Transcriber = TranscriberFactory.make(
            configuration: configuration)

        let menuBar = MenuBarController()
        let controller = DictationController(configuration: configuration,
                                             transcriber: transcriber)
        controller.onStateChange = { [weak menuBar] state in menuBar?.update(state: state) }
        controller.onEventChange = { [weak menuBar] event in menuBar?.describeEvent(event) }
        menuBar.describeBackend(transcriber is UnavailableTranscriber
            ? "no speech backend"
            : "model: \(transcriber.identifier)")
        menuBar.describeEvent((transcriber as? UnavailableTranscriber)?.reason ?? "ready")
        menuBar.onQuit = { NSApp.terminate(nil) }

        // Settings write straight through: every control saves and applies as
        // it changes, so the shortcut a user records is live before the window
        // closes. `apply` rebinds the hotkey and swaps activation mode without
        // a restart.
        let settings = SettingsWindowController(configuration: configuration) { [weak controller, weak menuBar] updated in
            controller?.apply(configuration: updated)
            menuBar?.describeShortcut(updated.hotkey.displayString,
                                      activation: updated.activation.rawValue,
                                      fix: updated.fixHotkey.displayString)
        }
        menuBar.onOpenSettings = { settings.show() }

        // Fix-last (SPEC §1): the primary and, for now, only way a correction
        // is captured. Nothing watches the user's document, so a fix made
        // there is invisible; this is the explicit action that replaces it.
        // Captured by value: the home directory and the identifier do not
        // change for the life of the process, and capturing `self` to reach
        // them would keep the delegate alive through the panel.
        let home = configuration.home
        let backendIdentifier = transcriber.identifier
        let correction = CorrectionPanelController(
            home: home
        ) { [weak controller, weak menuBar] corrected, replace in
            guard let controller, let last = controller.lastUtterance else { return }
            let latency = last.ageMillis
            if replace {
                do {
                    try controller.replaceLastUtterance(with: corrected)
                } catch {
                    menuBar?.describeEvent("could not fix the text: \(error)")
                }
            }
            Task { @MainActor in
                do {
                    let verdict = try await CorrectionRecorder.record(
                        hypothesis: last.hypothesis,
                        final: corrected,
                        latencyMillis: latency,
                        appBundleIdentifier: last.appBundleIdentifier,
                        model: backendIdentifier,
                        home: home)
                    // The verdict is worth surfacing, not swallowing: a
                    // quarantined correction is one the user will have to
                    // adjudicate, and a revision is one that will never be
                    // trained on. Both look identical to "saved" otherwise.
                    let summary = Self.describe(verdict)
                    menuBar?.describeEvent(summary)
                    Diagnostics.log("correct", summary)
                } catch {
                    menuBar?.describeEvent("correction not saved: \(error)")
                    Diagnostics.log("correct", "not saved: \(error)")
                }
            }
        }
        controller.onFixLast = { [weak controller, weak correction] in
            guard let controller else { return }
            correction?.show(utterance: controller.lastUtterance,
                             canReplace: controller.canReplaceLastUtterance)
        }
        self.correction = correction
        menuBar.describeShortcut(configuration.hotkey.displayString,
                                 activation: configuration.activation.rawValue,
                                 fix: configuration.fixHotkey.displayString)
        self.settings = settings

        do {
            try controller.start()
        } catch {
            presentFatal("Could not register the dictation hotkey: \(error)")
            return
        }

        self.menuBar = menuBar
        self.controller = controller
    }

    /// One line saying what F1 made of a correction.
    private static func describe(_ verdict: CorrectionRecorder.Verdict) -> String {
        if verdict.needsReview {
            return "saved for review — it does not look like an ASR error "
                 + "(\(verdict.failed_signals.joined(separator: ", ")))"
        }
        if !verdict.isTrainable {
            return """
                saved, but read as a rewrite rather than a mishearing, so it \
                will not be trained on
                """
        }
        return "correction saved"
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "cochlea could not start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

/// Entry point.
///
/// Not `main.swift`: top-level code is nonisolated in Swift 5.10, so
/// constructing a `@MainActor` `AppDelegate` there is an actor-isolation
/// error. `@main` on a `@MainActor` type puts the entry point on the main
/// actor instead, which is where an AppKit app belongs anyway.
@main
@MainActor
enum CochleaMain {
    /// `NSApplication.delegate` is a weak reference. A local would be
    /// deallocated the moment `main()` returned into `run()`, so the delegate
    /// is held for the process lifetime here.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
