import AppKit
import CochleaASR
import CochleaCore
import SwiftUI

/// The fix-last panel: the primary way a correction is ever captured.
///
/// SPEC §1 rules out watching arbitrary text fields through the Accessibility
/// API, so an edit the user makes in their own document is invisible to this
/// app by design. Corrections are captured only through an explicit action,
/// and this is that action. The consequence the spec names is real: capture
/// volume will be far below error volume, which is why this has to be cheap
/// enough that someone actually reaches for it — one chord, one field, Enter.
@MainActor
final class CorrectionPanelController {

    private var window: NSPanel?
    private let home: URL
    private let onCommit: (String, Bool) -> Void

    init(home: URL, onCommit: @escaping (String, Bool) -> Void) {
        self.home = home
        self.onCommit = onCommit
    }

    /// Show the panel, or tell the user why there is nothing to fix.
    func show(utterance: DictationController.LastUtterance?, canReplace: Bool) {
        guard let utterance else {
            NSSound.beep()
            return
        }
        close()
        let model = CorrectionModel(
            hypothesis: utterance.hypothesis,
            injectedCount: utterance.injected.count,
            canReplace: canReplace,
            ageMillis: utterance.ageMillis)
        model.commit = { [weak self] text, replace in
            self?.close()
            self?.onCommit(text, replace)
        }
        model.cancel = { [weak self] in self?.close() }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Fix the last thing you said"
        panel.contentViewController = NSHostingController(
            rootView: CorrectionView(model: model))
        panel.isFloatingPanel = true
        // The panel takes focus on purpose: the whole interaction is typing
        // into it. A non-activating panel would leave keystrokes going to the
        // document behind, which is where the wrong text already is.
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

@MainActor
final class CorrectionModel: ObservableObject {
    @Published var text: String
    let hypothesis: String
    let injectedCount: Int
    let canReplace: Bool
    let ageMillis: Int

    var commit: ((String, Bool) -> Void)?
    var cancel: (() -> Void)?

    init(hypothesis: String, injectedCount: Int, canReplace: Bool, ageMillis: Int) {
        self.hypothesis = hypothesis
        self.text = hypothesis
        self.injectedCount = injectedCount
        self.canReplace = canReplace
        self.ageMillis = ageMillis
    }

    var isChanged: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            != hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CorrectionView: View {
    @ObservedObject var model: CorrectionModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("cochlea heard:")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $model.text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .font(.body)
                .focused($focused)
                .onSubmit { if model.isChanged { model.commit?(model.text, model.canReplace) } }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { model.cancel?() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.canReplace {
                    Button("Just remember it") { model.commit?(model.text, false) }
                        .disabled(!model.isChanged)
                    Button("Fix it and remember") { model.commit?(model.text, true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.isChanged)
                } else {
                    Button("Remember it") { model.commit?(model.text, false) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.isChanged)
                }
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    /// Says what each button will actually do, because one of them edits the
    /// user's document and there is no way to preview that.
    private var explanation: String {
        guard model.canReplace else {
            return """
                Too long ago to take the text back safely — cochlea cannot \
                see your document, so it cannot tell whether your cursor has \
                moved. It will remember the correction; fix the text \
                yourself.
                """
        }
        return """
            \"Fix it\" deletes the last \(model.injectedCount) characters at \
            your cursor and types this instead. If you have moved the cursor \
            since, choose \"Just remember it\".
            """
    }
}

/// Files a correction through `dictate`, which applies the F1 filter.
enum CorrectionRecorder {

    struct Verdict: Decodable {
        let id: String
        let attribution: String
        let reason: String
        let failed_signals: [String]

        /// Whether this correction will ever be trained on.
        var isTrainable: Bool { attribution == "correction" }
        var needsReview: Bool { attribution == "quarantined" }
    }

    /// Record one correction. Returns what F1 made of it.
    ///
    /// The verdict is not decided here. F1's three-signal heuristic lives in
    /// `cochlea.attribution` and a second implementation in Swift would be two
    /// rules that must agree forever — the same reason extraction stayed in
    /// the helper.
    static func record(hypothesis: String, final: String, latencyMillis: Int,
                       appBundleIdentifier: String?, model: String,
                       home: URL) async throws -> Verdict {
        guard let executable = SidecarTranscriber.locateExecutable() else {
            throw RecorderError.helperMissing
        }
        var arguments = [
            "correct",
            "--hypothesis", hypothesis,
            "--final", final,
            "--latency-ms", String(latencyMillis),
            "--source", "fix_last",
            "--model", model,
            "--json",
        ]
        if let appBundleIdentifier { arguments += ["--app", appBundleIdentifier] }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["COCHLEA_HOME"] = home.path
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let text = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RecorderError.failed(text.isEmpty ? "recording failed" : text)
        }
        return try JSONDecoder().decode(Verdict.self, from: data)
    }

    enum RecorderError: Error, CustomStringConvertible {
        case helperMissing
        case failed(String)

        var description: String {
            switch self {
            case .helperMissing:
                return """
                    the `dictate` helper was not found, so the correction \
                    could not be saved. The text was still fixed.
                    """
            case .failed(let reason):
                return reason
            }
        }
    }
}
