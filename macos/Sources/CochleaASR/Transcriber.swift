import CochleaCore
import Foundation

/// What M0 needs from a speech model, and nothing more.
///
/// SPEC §7 leaves the default base model open pending a benchmark of Whisper
/// turbo against SenseVoice-Small — and that choice changes the biasing
/// implementation, because SenseVoice is non-autoregressive. Keeping the app
/// behind this protocol is what lets that benchmark happen without rewriting
/// the capture path.
public protocol Transcriber: AnyObject, Sendable {
    var identifier: String { get }

    /// F19: called at launch so the first hotkey press does not pay load time.
    func warmUp() async throws

    /// 16 kHz mono float samples in, text out.
    func transcribe(samples: [Float]) async throws -> TranscriptionResult
}

public struct TranscriptionResult: Sendable {
    public let text: String
    public let language: String?
    /// Wall-clock time inside the model, for the F18 latency budget.
    public let inferenceMillis: Int

    public init(text: String, language: String? = nil, inferenceMillis: Int) {
        self.text = text
        self.language = language
        self.inferenceMillis = inferenceMillis
    }
}

/// The transcriber used when no model is installed.
///
/// It returns nothing rather than fabricating text: a dictation app that types
/// invented words at the user's cursor is worse than one that types nothing.
public final class UnavailableTranscriber: Transcriber, @unchecked Sendable {
    public let identifier = "none"
    public init() {}
    public func warmUp() async throws {}
    public func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        throw TranscriberError.noModelInstalled
    }
}

public enum TranscriberError: Error, CustomStringConvertible {
    case noModelInstalled
    case notWarmedUp

    public var description: String {
        switch self {
        case .noModelInstalled:
            return "no speech model is installed. cochlea ships no weights "
                 + "(SPEC F21); run the first-run download once ModelCatalog is populated."
        case .notWarmedUp:
            return "model was not warmed up; call warmUp() at launch (SPEC F19)"
        }
    }
}
