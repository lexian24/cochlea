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
    /// Why there is no transcriber, in a sentence the user can act on. A bare
    /// "unavailable" sends people to the issue tracker; naming the missing
    /// piece sends them to the fix.
    public let reason: String

    public init(reason: String = TranscriberError.noModelInstalled.description) {
        self.reason = reason
    }

    public func warmUp() async throws {}
    public func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        throw TranscriberError.unavailable(reason)
    }
}

public enum TranscriberError: Error, CustomStringConvertible {
    case noModelInstalled
    case notWarmedUp
    case unavailable(String)

    public var description: String {
        switch self {
        case .noModelInstalled:
            return "no speech model is installed. cochlea ships no weights "
                 + "(SPEC F21); it is downloaded and checksum-verified on first run."
        case .notWarmedUp:
            return "model was not warmed up; call warmUp() at launch (SPEC F19)"
        case .unavailable(let reason):
            return reason
        }
    }
}
