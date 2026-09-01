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
                     ? """
                         Detection costs about 180 ms per utterance and can \
                         pick wrong on a short one. Choose a language if you \
                         do not switch.
                         """
                     : "Fixed. Faster, and it cannot guess wrong.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 6)

            Section {
                Toggle("Type as I speak", isOn: Binding(
                    get: { model.configuration.mode == .liveStreaming },
                    set: { model.configuration.mode = $0 ? .liveStreaming : .commitOnRelease }
                ))
                Text(model.configuration.mode == .liveStreaming
                     ? """
                         Each phrase appears at your cursor when you pause, \
                         instead of all at once at the end.
                         """
                     : """
                         Nothing is typed until you stop. Slower to appear, \
                         but the whole utterance is transcribed together.
                         """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("When text appears").font(.headline)
            }

            if model.configuration.activation != .holdToTalk {
                Divider().padding(.vertical, 6)
                Section {
                    Stepper(
                        "Stop listening after \(model.configuration.maximumUtteranceSeconds / 60) min",
                        value: $model.configuration.maximumUtteranceSeconds,
                        in: 60...1800, step: 60)
                    Text("""
                        Without holding a key, the microphone can be left \
                        open. This closes it. Nothing already said is \
                        discarded.
                        """)
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
                    Text("Dictate")
                    Spacer()
                    ShortcutRecorder(binding: $model.configuration.hotkey) { reason in
                        rejection = reason
                    }
                    .frame(width: 150, height: 26)
                }
                HStack {
                    Text("Fix what it just typed")
                    Spacer()
                    ShortcutRecorder(binding: $model.configuration.fixHotkey) { reason in
                        rejection = reason
                    }
                    .frame(width: 150, height: 26)
                }
                if let rejection {
                    Text(rejection).font(.callout).foregroundStyle(.red)
                }
                Text("""
                    Click a field, then press the combination you want. It \
                    applies immediately.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shortcuts").font(.headline)
            }

            Divider().padding(.vertical, 6)

            Section {
                Text("""
                    cochlea registers one system-wide shortcut and sees \
                    nothing else you type. It does not watch your keyboard.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("""
                    The Fn key cannot be used: macOS does not make it \
                    available to apps as a shortcut.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.configuration.hotkey) { _ in rejection = nil }
        .onChange(of: model.configuration.fixHotkey) { _ in rejection = nil }
    }
}

// MARK: - Learning

/// What cochlea knows, how it got there, and what it still cannot do.
///
/// The tab answers three questions in the order a user actually asks them:
/// what has it learned, how do I teach it, and when does it train. The third
/// answer is "not yet", and saying so plainly beats a screen that implies
/// otherwise by having controls for it.
struct LearningSettings: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var lexicon: LexiconModel

    init(model: SettingsModel) {
        self.model = model
        _lexicon = StateObject(wrappedValue: LexiconModel(home: model.configuration.home))
    }

    // Broken into computed sub-views rather than written as one `body`.
    //
    // Not a style preference: as a single expression this failed to compile on
    // CI with "unable to type-check this expression in reasonable time", while
    // building fine locally. SwiftUI's builders are generic enough that the
    // solver's cost grows sharply with the size of one body, and a machine
    // fast enough to get away with it is not the machine that has to.
    var body: some View {
        Form {
            knownWords
            Divider().padding(.vertical, 6)
            importer
            Divider().padding(.vertical, 6)
            training
        }
        .formStyle(.grouped)
        .onAppear { lexicon.reload() }
        .sheet(item: $lexicon.pendingSpeakers) { pending in
            SpeakerPicker(pending: pending) { chosen in
                lexicon.propose(source: pending.source, author: chosen)
            } cancel: {
                lexicon.pendingSpeakers = nil
            }
        }
        .sheet(item: $lexicon.proposal) { proposal in
            ProposalSheet(proposal: proposal) {
                lexicon.commit()
            } cancel: {
                lexicon.proposal = nil
            }
        }
    }

    @ViewBuilder
    private var knownWords: some View {
        Section {
            if lexicon.entries.isEmpty {
                Text("Nothing yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("""
                    cochlea does not know your vocabulary until you give it \
                    some. Import a file below to get started.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                List(lexicon.entries) { entry in
                    LexiconRow(entry: entry) { lexicon.remove(entry.term) }
                }
                .frame(minHeight: 120, maxHeight: 180)
                Text("Changes take effect the next time the ASR helper starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Words cochlea listens for").font(.headline)
        }
    }

    @ViewBuilder
    private var importer: some View {
        Section {
            HStack {
                Button("Import from a file…") { lexicon.chooseFile() }
                    .disabled(lexicon.isRunning)
                if lexicon.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                if !lexicon.entries.isEmpty {
                    Button("Show the file") { lexicon.revealInFinder() }
                }
            }
            Text("""
                A chat export, your notes, anything you have written. \
                cochlea reads it, proposes what it found, and writes nothing \
                until you say yes.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let problem = lexicon.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Teach it your vocabulary").font(.headline)
        }
    }

    @ViewBuilder
    private var training: some View {
        Section {
            Text("Not yet. Nothing on this machine trains a model today.")
                .font(.callout)
            Text("""
                Biasing above is instant and needs no training: the words \
                you import take effect the next time dictation starts. \
                Training a model on your corrections is a later stage, and \
                it is gated — an adapter that scores worse on held-out data \
                than the one it replaces is never promoted. When it does run \
                it will be while you are idle and on power, and never while \
                you are dictating.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("""
                Corrections are being collected now: press \
                \(model.configuration.fixHotkey.displayString) after \
                dictation types something wrong. What is still missing is \
                the part that trains on them.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Show what has been collected") { showStore() }
                Spacer()
            }
        } header: {
            Text("When does it train?").font(.headline)
        }
    }

    /// Reveal the correction store rather than summarising it in the window.
    ///
    /// The store is SQLite and human-inspectable on purpose (SPEC §1.3), and
    /// `dictate stats` and `dictate review` already report it properly.
    /// Reimplementing either here would be a second, worse view of the same
    /// data with no way to act on it.
    private func showStore() {
        let store = model.configuration.home
            .appendingPathComponent("corrections.db")
        if FileManager.default.fileExists(atPath: store.path) {
            NSWorkspace.shared.activateFileViewerSelecting([store])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([model.configuration.home])
        }
    }

    private var summary: String {
        let total = lexicon.entries.count
        let phrases = lexicon.entries.filter(\.isPhrase).count
        let used = lexicon.entries.filter { $0.hits > 0 }.count
        var parts = ["\(total) entries"]
        if phrases > 0 { parts.append("\(phrases) of them phrases") }
        parts.append(used == 0 ? "none used yet" : "\(used) used so far")
        return parts.joined(separator: ", ") + "."
    }
}

/// One entry in the list: what it is, whether it has ever won, and a way out.
struct LexiconRow: View {
    let entry: LexiconFile.Entry
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isPhrase ? "text.quote" : "textformat.abc")
                .foregroundStyle(.secondary)
                .help(entry.isPhrase
                      ? "A phrase. Only boosted in context."
                      : "A single word.")
            Text(entry.term)
            Spacer()
            Text(usage).font(.caption).foregroundStyle(.secondary)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Stop biasing towards this")
        }
    }

    private var usage: String {
        entry.hits == 0 ? "not used yet" : "used \(entry.hits)x"
    }
}

/// Reads the lexicon and drives `dictate import` for the settings window.
@MainActor
final class LexiconModel: ObservableObject {

    @Published var entries: [LexiconFile.Entry] = []
    @Published var problem: String?
    @Published var isRunning = false
    @Published var proposal: PendingProposal?
    @Published var pendingSpeakers: PendingSpeakers?

    /// A proposal waiting for the user to accept it. Carries the source and
    /// author so accepting can re-run the same import with `--commit` rather
    /// than trusting the app to have kept the terms straight.
    struct PendingProposal: Identifiable {
        let id = UUID()
        let source: URL
        let author: String?
        let result: LexiconImporter.Proposal
    }

    struct PendingSpeakers: Identifiable {
        let id = UUID()
        let source: URL
        let speakers: [LexiconImporter.Speaker]
    }

    private let home: URL

    init(home: URL) { self.home = home }

    private var url: URL { home.appendingPathComponent("lexicon.json") }

    func reload() {
        entries = LexiconFile.load(from: url).sorted
    }

    func remove(_ term: String) {
        var file = LexiconFile.load(from: url)
        file.remove(term)
        do {
            try file.save(to: url)
            entries = file.sorted
        } catch {
            problem = "Could not update the lexicon: \(error.localizedDescription)"
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a file to learn from"
        panel.message = "A chat export, your notes, anything you have written."
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        propose(source: source, author: nil)
    }

    func propose(source: URL, author: String?) {
        pendingSpeakers = nil
        problem = nil
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                let result = try await LexiconImporter.run(
                    source: source, author: author, commit: false, home: home)
                if result.isEmpty {
                    problem = """
                        Nothing in that file looked like vocabulary worth \
                        learning. Words the recogniser already knows are \
                        skipped on purpose — boosting them can only make it \
                        wrong.
                        """
                    return
                }
                proposal = PendingProposal(source: source, author: author, result: result)
            } catch LexiconImporter.ImportError.needsAuthor(let speakers) {
                pendingSpeakers = PendingSpeakers(source: source, speakers: speakers)
            } catch {
                problem = String(describing: error)
            }
        }
    }

    func commit() {
        guard let pending = proposal else { return }
        proposal = nil
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                _ = try await LexiconImporter.run(
                    source: pending.source, author: pending.author,
                    commit: true, home: home)
                reload()
            } catch {
                problem = String(describing: error)
            }
        }
    }
}

/// "Which one of these is you?" — invariant 3, as a question.
struct SpeakerPicker: View {
    let pending: LexiconModel.PendingSpeakers
    let choose: (String) -> Void
    let cancel: () -> Void
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which one is you?").font(.headline)
            Text("""
                This file is a conversation. cochlea will only learn from \
                the lines you wrote — importing the other side would put \
                someone else's words into your dictation.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            List(pending.speakers, selection: $selected) { speaker in
                HStack {
                    Text(speaker.name)
                    Spacer()
                    Text("\(speaker.lines) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(speaker.name)
            }
            .frame(height: 150)
            HStack {
                Button("Cancel", role: .cancel) { cancel() }
                Spacer()
                Button("Continue") { if let selected { choose(selected) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// What an import would add, before it adds it.
struct ProposalSheet: View {
    let proposal: LexiconModel.PendingProposal
    let accept: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add these to your lexicon?").font(.headline)
            Text("""
                From \(proposal.result.samples) lines you wrote. Nothing has \
                been saved yet.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            List {
                if !proposal.result.phrases.isEmpty {
                    Section("Phrases — boosted only in context") {
                        ForEach(proposal.result.phrases) { row(for: $0) }
                    }
                }
                if !proposal.result.terms.isEmpty {
                    Section("Words") {
                        ForEach(proposal.result.terms) { row(for: $0) }
                    }
                }
            }
            .frame(height: 220)
            if !proposal.result.rejected.isEmpty {
                Text("""
                    Skipped, because biasing cannot separate a homophone and \
                    boosting one makes things worse:
                    """
                   + proposal.result.rejected.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { cancel() }
                Spacer()
                Button("Add") { accept() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func row(for candidate: LexiconImporter.Proposal.Candidate) -> some View {
        HStack {
            Text(candidate.term)
            Spacer()
            Text("you wrote it \(candidate.count)x")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                Text("""
                    Off by default, and off is fully functional — the parts \
                    that learn your vocabulary never need audio. Turning \
                    this on stores processed audio features, encrypted, so a \
                    future version can adapt to your voice.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("What is kept").font(.headline)
            }

            Divider().padding(.vertical, 6)

            Section {
                Text("""
                    Nothing leaves this Mac. There is no account, no server \
                    and no telemetry. Speech recognition runs locally.
                    """)
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
