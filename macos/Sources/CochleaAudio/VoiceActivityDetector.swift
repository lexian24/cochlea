import Foundation

/// Energy-and-zero-crossing voice activity detection.
///
/// Deliberately simple. M0's job is to segment an utterance the user is
/// deliberately dictating while holding a hotkey, not to find speech in an
/// open room. A hangover window keeps short pauses between words from ending
/// the utterance mid-sentence.
public struct VoiceActivityDetector: Sendable {

    public struct Parameters: Sendable {
        /// RMS below this is treated as silence.
        public var energyThreshold: Float = 0.012
        /// Silence must persist this long before the utterance is considered over.
        public var hangoverSeconds: Double = 0.6
        /// Utterances shorter than this are discarded as accidental taps.
        public var minimumSpeechSeconds: Double = 0.25

        public init() {}
    }

    public var parameters: Parameters

    public init(parameters: Parameters = .init()) {
        self.parameters = parameters
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    public func isSpeech(_ samples: [Float]) -> Bool {
        Self.rms(samples) >= parameters.energyThreshold
    }
}

/// Accumulates frames into one utterance, ending it after enough trailing
/// silence.
public final class Segmenter {
    private let vad: VoiceActivityDetector
    private let sampleRate: Double
    private var samples: [Float] = []
    private var trailingSilenceSeconds: Double = 0
    private var speechSeconds: Double = 0

    public init(vad: VoiceActivityDetector = .init(), sampleRate: Double = 16_000) {
        self.vad = vad
        self.sampleRate = sampleRate
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Appends a frame. Returns the finished utterance when silence ends it.
    public func accept(frame: [Float]) -> [Float]? {
        let duration = Double(frame.count) / sampleRate
        samples.append(contentsOf: frame)
        if vad.isSpeech(frame) {
            speechSeconds += duration
            trailingSilenceSeconds = 0
            return nil
        }
        trailingSilenceSeconds += duration
        guard trailingSilenceSeconds >= vad.parameters.hangoverSeconds else { return nil }
        return finish()
    }

    /// Ends the utterance now, as when the user releases the hotkey.
    @discardableResult
    public func finish() -> [Float]? {
        defer { reset() }
        guard speechSeconds >= vad.parameters.minimumSpeechSeconds else { return nil }
        return samples
    }

    public func reset() {
        samples.removeAll(keepingCapacity: true)
        trailingSilenceSeconds = 0
        speechSeconds = 0
    }
}
