import AppKit
import CochleaCore
import SwiftUI

/// Settings, reachable from the menu bar icon.
///
/// SwiftUI rather than AppKit, and the package stays dependency-free either
/// way — SwiftUI ships in the SDK. The reason is quantity: this is a form, and
/// a form in AppKit is several hundred lines of layout constraints that say
/// nothing about the product. Hosted in a plain `NSWindow` rather than a
/// `Settings` scene, because the app is an `NSApplication` accessory with no
/// `App` scene tree to hang one on.
///
/// Every control writes straight through to `Configuration` and saves, and
/// `onChange` applies it live. There is no Apply button: a settings screen that
/// can be wrong until you press something is a settings screen people misread.
@MainActor
final class SettingsWindowController {

    private var window: NSWindow?
    private let onChange: (Configuration) -> Void
    private var configuration: Configuration

    init(configuration: Configuration, onChange: @escaping (Configuration) -> Void) {
        self.configuration = configuration
        self.onChange = onChange
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SettingsModel(configuration: configuration) { [weak self] updated in
            self?.configuration = updated
            self?.onChange(updated)
        }
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "cochlea Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 460))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class SettingsModel: ObservableObject {

    @Published var configuration: Configuration { didSet { persist() } }
    @Published var problem: String?

    private let onChange: (Configuration) -> Void

    init(configuration: Configuration, onChange: @escaping (Configuration) -> Void) {
        self.configuration = configuration
        self.onChange = onChange
    }

    private func persist() {
        do {
            try configuration.save()
        } catch {
            // Saving is how a setting outlives the session; if it fails the
            // user needs to know now, not on next launch when it has reverted.
            problem = "Could not save settings: \(error.localizedDescription)"
        }
        onChange(configuration)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            DictationSettings(model: model)
                .tabItem { Label("Dictation", systemImage: "mic") }
            ShortcutSettings(model: model)
                .tabItem { Label("Shortcuts", systemImage: "command") }
            LearningSettings(model: model)
                .tabItem { Label("Learning", systemImage: "brain") }
            PrivacySettings(model: model)
                .tabItem { Label("Privacy", systemImage: "lock") }
        }
        .padding(20)
        .frame(width: 620, height: 460)
    }
}

// MARK: - Dictation

struct DictationSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Activation", selection: $model.configuration.activation) {
                    ForEach(Configuration.Activation.allCases, id: \.self) { mode in
                        Text(label(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(model.configuration.activation.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How dictation starts and stops").font(.headline)
            }

            Divider().padding(.vertical, 6)

            Section {
                Picker("Language", selection: Binding(
                    get: { model.configuration.language ?? "" },
                    set: { model.configuration.language = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Detect automatically").tag("")
                    Text("English").tag("en")
                    Text("Chinese").tag("zh")
                }
                Text(model.configuration.language == nil
                     ? "Detection costs about 180 ms per utterance and can pick wrong "
                     + "on a short one. Choose a language if you do not switch."
                     : "Fixed. Faster, and it cannot guess wrong.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.configuration.activation != .holdToTalk {
                Divider().padding(.vertical, 6)
                Section {
                    Stepper(
                        "Stop listening after \(model.configuration.maximumUtteranceSeconds / 60) min",
                        value: $model.configuration.maximumUtteranceSeconds,
                        in: 60...1800, step: 60)
                    Text("Without holding a key, the microphone can be left open. "
                       + "This closes it. Nothing already said is discarded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func label(for mode: Configuration.Activation) -> String {
        switch mode {
        case .holdToTalk: return "Hold to talk"
        case .toggle:     return "Press to start, press to stop"
        case .hybrid:     return "Both — hold, or tap to keep listening"
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var rejection: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Dictation")
                    Spacer()
                    ShortcutRecorder(binding: $model.configuration.hotkey) { reason in
                        rejection = reason
                    }
                    .frame(width: 150, height: 26)
                }
                if let rejection {
                    Text(rejection).font(.callout).foregroundStyle(.red)
                }
                Text("Click the field, then press the combination you want. "
                   + "It applies immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shortcuts").font(.headline)
            }

            Divider().padding(.vertical, 6)

            Section {
                Text("cochlea registers one system-wide shortcut and sees nothing "
                   + "else you type. It does not watch your keyboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("The Fn key cannot be used: macOS does not make it available "
                   + "to apps as a shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.configuration.hotkey) { _ in rejection = nil }
    }
}

// MARK: - Learning

struct LearningSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Text("Not built yet.").font(.headline)
                Text("cochlea is designed to learn your words from corrections you "
                   + "make, and from text you import. The storage, the filter that "
                   + "tells a correction from a rewrite, and the check that stops a "
                   + "bad model shipping are all written and tested. What is missing "
                   + "is the part that trains, and the screens for it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Until then the command line does the parts that work:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("dictate import gitlog ~/your/repo\ndictate stats")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
            } header: {
                Text("Learning from your corrections").font(.headline)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Keep audio features for voice adaptation",
                       isOn: $model.configuration.acousticRetentionEnabled)
                Text("Off by default, and off is fully functional — the parts that "
                   + "learn your vocabulary never need audio. Turning this on stores "
                   + "processed audio features, encrypted, so a future version can "
                   + "adapt to your voice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("What is kept").font(.headline)
            }

            Divider().padding(.vertical, 6)

            Section {
                Text("Nothing leaves this Mac. There is no account, no server and "
                   + "no telemetry. Speech recognition runs locally.")
                    .font(.callout)
                Text("Everything cochlea stores is in ~/.cochlea.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [model.configuration.home])
                }
            }
        }
        .formStyle(.grouped)
    }
}
