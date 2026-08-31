import Foundation

/// Energy-and-zero-crossing voice activity detection.
///
/// Deliberately simple. M0's job is to segment an utterance the user is
/// deliberately dictating while holding a hotkey, not to find speech in an
/// open room. A hangover window keeps short pauses between words from ending
/// the utterance mid-sentence.
public struct VoiceActivityDetector: Sendable {

    public struct Parameters: Sendable {
        /// The absolute floor. Nothing quieter than this is speech however
        /// quiet the room is, so a silent room cannot drive the threshold to
        /// zero and start transcribing its own noise.
        public var floorThreshold: Float = 0.012

        /// How far above the measured noise floor a frame must sit to count
        /// as speech.
        ///
        /// This replaces a fixed threshold, which cannot work: measured on a
        /// MacBook Air in an ordinary room, the noise floor ran 0.0166–0.0386
        /// RMS against a fixed threshold of 0.012 — every single frame of
        /// silence counted as speech. Trailing silence never accumulated, the
        /// hangover never fired, and the accidental-tap guard never rejected
        /// anything, because both are the same signal. A threshold that a
        /// microphone's own noise clears is not a threshold.
        public var speechMultiplier: Float = 3.0

        /// Silence must persist this long before the utterance is considered
        /// over.
        ///
        /// Raised from 0.6 s once the detector started working. In
        /// commit-on-release the hotkey is the real signal and this is a
        /// safety net for a user who stops speaking without letting go, so it
        /// should be longer than a person pausing to think mid-sentence.
        /// 0.6 s is not.
        public var hangoverSeconds: Double = 1.5

        /// The threshold may never rise above this, however loud the room
        /// measures.
        ///
        /// Without a ceiling the adaptation has a failure worse than the one
        /// it fixes. The floor is seeded from the first frame of the
        /// utterance, so a user who presses and speaks immediately at a steady
        /// level seeds it with *speech*: the threshold went to 0.75, every
        /// frame read as silence, and the utterance was discarded as an
        /// accidental tap. Speech and a constant loud room are genuinely
        /// indistinguishable from one frame, so the fix is not a cleverer
        /// estimator but a bound on how wrong it is allowed to be. Ordinary
        /// speech sits at 0.1–0.3 RMS, so a threshold capped here still hears
        /// it whatever the estimate believes.
        public var maximumThreshold: Float = 0.08

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

    /// The level a frame has to clear, given what the room sounds like.
    public func threshold(noiseFloor: Float) -> Float {
        min(parameters.maximumThreshold,
            max(parameters.floorThreshold, noiseFloor * parameters.speechMultiplier))
    }

    public func isSpeech(_ samples: [Float], noiseFloor: Float) -> Bool {
        Self.rms(samples) >= threshold(noiseFloor: noiseFloor)
    }
}

/// Tracks what silence sounds like on this microphone, in this room, now.
///
/// Falls instantly and rises slowly, and rises only on frames that are not
/// already speech. Falling fast matters because the estimate starts at the
/// first frame, which is whatever the user happened to be doing — if that
/// frame was loud, one quiet frame corrects it. Rising slowly matters because
/// a sustained loud passage must not drag the floor up behind it and start
/// treating speech as background.
public struct NoiseFloor: Sendable {

    /// How quickly the estimate drifts upward on a non-speech frame.
    public var adaptationRate: Float = 0.05

    public private(set) var level: Float?

    public init() {}

    public mutating func observe(_ rms: Float, wasSpeech: Bool) {
        guard let current = level else { level = rms; return }
        if rms < current {
            level = rms
        } else if !wasSpeech {
            level = current + (rms - current) * adaptationRate
        }
    }

    public mutating func reset() { level = nil }
}

/// Accumulates frames into one utterance, ending it after enough trailing
/// silence.
public final class Segmenter {
    private let vad: VoiceActivityDetector
    private let sampleRate: Double
    private var samples: [Float] = []
    private var trailingSilenceSeconds: Double = 0
    private var speechSeconds: Double = 0
    private var noiseFloor = NoiseFloor()

    /// What the detector currently believes, for the log. Testing a detector
    /// you cannot see the state of is guesswork.
    public var currentThreshold: Float { vad.threshold(noiseFloor: noiseFloor.level ?? 0) }
    public var currentNoiseFloor: Float? { noiseFloor.level }

    public init(vad: VoiceActivityDetector = .init(), sampleRate: Double = 16_000) {
        self.vad = vad
        self.sampleRate = sampleRate
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Appends a frame. Returns the finished utterance when silence ends it.
    public func accept(frame: [Float]) -> [Float]? {
        let duration = Double(frame.count) / sampleRate
        samples.append(contentsOf: frame)
        let level = VoiceActivityDetector.rms(frame)
        let speech = level >= vad.threshold(noiseFloor: noiseFloor.level ?? 0)
        noiseFloor.observe(level, wasSpeech: speech)
        if speech {
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
        // The room is re-measured per utterance: the user may have moved, put
        // headphones on, or closed a window since the last one.
        noiseFloor.reset()
    }
}
