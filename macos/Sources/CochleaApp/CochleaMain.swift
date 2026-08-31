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
