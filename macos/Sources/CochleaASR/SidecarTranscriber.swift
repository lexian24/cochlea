import CochleaCore
import Foundation

/// A `Transcriber` backed by the Python ASR process (docs/DECISIONS.md D5).
///
/// SPEC §4 chose MLX so that inference and training share one weight format.
/// There is no Whisper for Swift MLX, and `mlx-tune` — the trainer §4 names —
/// is Python, so the Swift side was never going to train. Running inference in
/// Python keeps §4's rationale intact and, more importantly, puts M2's decode
/// loop in the same process as the lexicon it has to bias.
///
/// The child is spawned with pipes rather than reached over a socket: a pipe
/// needs no port, no path, no permission, and the kernel tears it down when
/// either side dies.
public actor SidecarTranscriber: Transcriber {

    public nonisolated let identifier: String

    private let executable: URL
    private let modelDirectory: URL
    private let io = SidecarIO()
    private var child: Process?

    public init(executable: URL, modelDirectory: URL, identifier: String) {
        self.executable = executable
        self.modelDirectory = modelDirectory
        self.identifier = identifier
    }

    /// Where `dictate` is likely to be, in the order worth trying.
    ///
    /// The Homebrew formula installs it, so on a machine that followed the
    /// README it is one of these. `PATH` is deliberately not consulted: a GUI
    /// app launched from Finder does not inherit the shell's `PATH`, so
    /// trusting it would work when run from a terminal and fail when
    /// double-clicked — the worst kind of bug to debug.
    public static let searchPaths = [
        "/opt/homebrew/bin/dictate",        // Homebrew, Apple Silicon
        "/usr/local/bin/dictate",           // Homebrew, Intel layout
    ]

    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["COCHLEA_DICTATE"] {
            return URL(fileURLWithPath: override)
        }
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Transcriber

    /// F19: pay the model load at launch, not on the first hotkey press.
    public func warmUp() async throws {
        try await ensureRunning()
        _ = try await io.request(["op": "warmup"], payload: nil)
    }

    public func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        try await ensureRunning()
        let started = Date()
        let reply = try await io.request(
            ["op": "transcribe", "samples": samples.count],
            payload: SidecarIO.encode(samples: samples))
        let text = reply["text"] as? String ?? ""
        // Prefer the child's own measurement: it excludes pipe transit, which
        // is what F18's budget is actually about.
        let inference = (reply["inference_ms"] as? NSNumber)?.intValue
            ?? Int(Date().timeIntervalSince(started) * 1000)
        return TranscriptionResult(text: text,
                                   language: reply["language"] as? String,
                                   inferenceMillis: inference)
    }

    // MARK: - process lifecycle

    private func ensureRunning() async throws {
        if let child, child.isRunning { return }
        try await start()
    }

    private func spawn() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SidecarError.executableNotFound(executable.path)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["asr-serve",
                             "--model", modelDirectory.path,
                             "--identifier", identifier]

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain stderr and throw it away. This is not optional hygiene: a pipe
        // nobody reads fills at 64 KB and then blocks the writer forever, and
        // the child writes MLX and HuggingFace chatter there by design — the
        // sidecar sends every stray write to stderr precisely so it cannot
        // corrupt the protocol on stdout. An undrained stderr would turn that
        // safeguard into a hang.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try process.run()
        child = process
        io.attach(input: stdout.fileHandleForReading,
                  output: stdin.fileHandleForWriting)
    }

    private func start() async throws {
        try spawn()
        // The child announces itself before accepting work, so a model that
        // cannot load fails here with the reason rather than on first use.
        let ready = try await io.readMessage()
        guard ready["ok"] as? Bool == true else {
            throw SidecarError.backend(ready["error"] as? String ?? "sidecar refused to start")
        }
        guard (ready["protocol"] as? NSNumber)?.intValue == SidecarIO.protocolVersion else {
            throw SidecarError.protocolMismatch(
                expected: SidecarIO.protocolVersion,
                found: (ready["protocol"] as? NSNumber)?.intValue ?? -1)
        }
    }

    public func shutdown() {
        io.close()
        child?.terminate()
        child = nil
    }
}

public enum SidecarError: Error, CustomStringConvertible {
    case executableNotFound(String)
    case protocolMismatch(expected: Int, found: Int)
    case backend(String)
    case closed

    public var description: String {
        switch self {
        case .executableNotFound(let path):
            return "the `dictate` helper was not found at \(path). cochlea's "
                 + "ASR runs in Python (D5); install it with `brew install "
                 + "cochlea`, or set COCHLEA_DICTATE to its path."
        case .protocolMismatch(let expected, let found):
            return "sidecar speaks protocol \(found), this app speaks "
                 + "\(expected). The app and the `dictate` CLI are different "
                 + "versions; update whichever is older."
        case .backend(let message):
            return message
        case .closed:
            return "the ASR process exited"
        }
    }
}
