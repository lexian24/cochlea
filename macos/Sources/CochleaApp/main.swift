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

    private var configuration = Configuration()
    private var menuBar: MenuBarController?
    private var controller: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            try configuration.ensureHomeExists()
        } catch {
            presentFatal("Could not create \(configuration.home.path): \(error)")
            return
        }

        // No model ships with the binary (F21) and ModelCatalog is empty until
        // the M0 benchmark and the F23 licence audit are done, so the app runs
        // with a transcriber that refuses rather than one that invents text.
        let transcriber: Transcriber = UnavailableTranscriber()

        let menuBar = MenuBarController()
        let controller = DictationController(configuration: configuration,
                                             transcriber: transcriber)
        controller.onStateChange = { [weak menuBar] state in menuBar?.update(state: state) }
        menuBar.onQuit = { NSApp.terminate(nil) }

        do {
            try controller.start()
        } catch {
            presentFatal("Could not register the dictation hotkey: \(error)")
            return
        }

        self.menuBar = menuBar
        self.controller = controller
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
