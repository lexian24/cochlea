import CochleaASR
import CochleaCore
import Foundation

/// Runs `dictate import` and reads back what it proposes.
///
/// Extraction is not reimplemented here, and that is the point. Admission
/// enforces F5 (a homophone cannot be fixed by biasing) and F2 (the boost cap),
/// and a second implementation in Swift would be two sets of rules that have to
/// agree forever — with the Swift one, inevitably, drifting. The helper already
/// exists for ASR (D5); this is the same helper answering a different question.
///
/// The two-phase shape is deliberate and matches the CLI exactly: a run without
/// `--commit` writes nothing and returns what it *would* add. This is text
/// lifted out of the user's private messages, so the least the app can do
/// before keeping any of it is show them what it took.
enum LexiconImporter {

    struct Proposal: Decodable {
        struct Candidate: Decodable, Identifiable, Hashable {
            let term: String
            let count: Int
            var id: String { term }
        }
        struct Variant: Decodable, Identifiable, Hashable {
            let a: String
            let b: String
            let count_a: Int
            let count_b: Int
            var id: String { a + "/" + b }
        }
        let samples: Int
        let terms: [Candidate]
        let phrases: [Candidate]
        let rejected: [String]
        let variants: [Variant]
        let committed: Bool
        let entries: Int

        var isEmpty: Bool { terms.isEmpty && phrases.isEmpty }
    }

    /// A speaker in a chat export, with how many lines they wrote.
    struct Speaker: Decodable, Identifiable, Hashable {
        let name: String
        let lines: Int
        var id: String { name }
    }

    struct Failure: Decodable {
        let error: String
        let speakers: [Speaker]?
    }

    enum ImportError: Error, CustomStringConvertible {
        /// The file holds a conversation and the app has to ask who the user is
        /// before it can import anything. Invariant 3: importing the other side
        /// would put someone else's vocabulary into the user's dictation.
        case needsAuthor([Speaker])
        case helperMissing
        case failed(String)

        var description: String {
            switch self {
            case .needsAuthor:
                return "this file has more than one speaker"
            case .helperMissing:
                return "the `dictate` helper was not found. cochlea's Homebrew "
                     + "formula installs it; without it, importing cannot run."
            case .failed(let reason):
                return reason
            }
        }
    }

    /// Ask what an import would add. Writes nothing unless `commit` is true.
    static func run(source: URL, author: String?, commit: Bool,
                    home: URL) async throws -> Proposal {
        guard let executable = SidecarTranscriber.locateExecutable() else {
            throw ImportError.helperMissing
        }
        var arguments = ["import", "text", source.path, "--json"]
        if let author, !author.isEmpty { arguments += ["--author", author] }
        if commit { arguments.append("--commit") }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // The helper resolves the lexicon path from COCHLEA_HOME, so the app
        // and the CLI cannot disagree about where the file is.
        var environment = ProcessInfo.processInfo.environment
        environment["COCHLEA_HOME"] = home.path
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Read before waiting. A pipe buffer that fills while the parent waits
        // deadlocks both processes, and an import of a large export is exactly
        // the case that produces enough output to fill one.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                if let speakers = failure.speakers, !speakers.isEmpty {
                    throw ImportError.needsAuthor(speakers)
                }
                throw ImportError.failed(failure.error)
            }
            let text = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImportError.failed(text.isEmpty ? "the import failed" : text)
        }
        do {
            return try JSONDecoder().decode(Proposal.self, from: data)
        } catch {
            throw ImportError.failed("could not read the helper's reply: \(error)")
        }
    }
}
