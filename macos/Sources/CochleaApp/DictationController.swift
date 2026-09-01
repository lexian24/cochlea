import CochleaASR
import CochleaAudio
import CochleaCore
import CochleaInput
import Foundation

/// Wires hotkey → capture → VAD → ASR → cursor.
///
/// This is the whole of M0's behaviour. There is deliberately no correction
/// capture, no lexicon and no training here: the spec's M0 is a good dictation
/// app with no learning at all, and F24 makes that the gate for everything
/// downstream.
@MainActor
public final class DictationController {

    public enum State: Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((State) -> Void)?

    private var configuration: Configuration
    private let capture = AudioCapture()
    private let injector = TextInjector()
    private let hotkey = HotkeyMonitor()
    private let latency = LatencyRecorder()
    private var segmenter = Segmenter()
    private var transcriber: Transcriber
    private var hasTranscribedOnce = false
    private var captureStartedAt: Date?
    /// Whether the microphone is open, which is *not* the same question as
    /// `state == .listening`. VAD can finish an utterance while the key is
    /// still held, moving the state to `.transcribing` and then `.idle` with
    /// the microphone deliberately still running for whatever is said next.
    /// Ending capture must therefore key off this, not off the state.
    private var isCapturing = false

    // MARK: - activation state
    //
    // Hold-to-talk needs none of this: press begins, release ends. Toggle and
    // hybrid do, because the key that starts an utterance is no longer the one
    // holding it open.

    /// Listening continues after the key came up, until the next press.
    private var isLatched = false
    /// When the current press went down, to tell a tap from a hold.
    private var pressedAt: Date?
    /// The press that just ended an utterance will be followed by a release
    /// that means nothing. Without this, that release latches a new session.
    private var ignoreNextRelease = false
    /// Closes the microphone if an utterance runs past the cap.
    private var utteranceTimeout: Task<Void, Never>?

    /// A one-line account of the last thing that happened, for the menu.
    public private(set) var lastEvent: String = "ready"
    public var onEventChange: ((String) -> Void)?

    /// The detector's state at the moment it decided, not afterwards.
    private func describeDecision() -> String {
        let floor = segmenter.decisionNoiseFloor
            .map { String(format: "%.4f", $0) } ?? "unmeasured"
        return "floor \(floor), threshold "
             + "\(String(format: "%.4f", segmenter.decisionThreshold))"
    }

    private func note(_ category: String, _ message: String) {
        Diagnostics.log(category, message)
        lastEvent = message
        onEventChange?(message)
    }

    public init(configuration: Configuration, transcriber: Transcriber) {
        self.configuration = configuration
        self.transcriber = transcriber
    }

    public func start() throws {
        hotkey.onPress = { [weak self] in
            Diagnostics.log("hotkey", "key down")
            Task { @MainActor in await self?.handlePress() }
        }
        hotkey.onRelease = { [weak self] in
            Diagnostics.log("hotkey", "key up")
            Task { @MainActor in await self?.handleRelease() }
        }
        try hotkey.register(configuration.hotkey)
        Diagnostics.banner([
            "transcriber: \(transcriber.identifier)",
            "model dir:   \(configuration.modelsDirectory.appendingPathComponent(configuration.modelIdentifier).path)",
            "microphone:  \(AudioCapture.hasPermission ? "granted" : "not yet granted")",
            "accessibility: \(AccessibilityPermission.isTrusted() ? "granted" : "not yet granted")",
            "language:    \(configuration.language ?? "auto-detect")",
            "hotkey:      \(configuration.hotkey.displayString) (\(configuration.activation.rawValue))",
        ])

        // F19: warm the model at launch so the first press does not pay load
        // time. Failure here is not fatal; it surfaces on first use instead —
        // but it is logged, because "the first press was slow" and "the helper
        // never started" look identical from the outside otherwise.
        // The audio graph's first-touch cost lands between key-down and the
        // microphone opening, where it eats the first word. Same reasoning as
        // the model warm-up below; it prompts for nothing.
        capture.prewarm()

        if configuration.keepModelResident {
            Task.detached { [transcriber] in
                let started = Date()
                do {
                    try await transcriber.warmUp()
                    Diagnostics.log("warmup", "model resident after "
                        + "\(Int(Date().timeIntervalSince(started) * 1000)) ms")
                } catch {
                    Diagnostics.log("warmup", "failed: \(error). The first "
                        + "hotkey press will report the reason.")
                }
            }
        }
    }

    public func stop() {
        try? hotkey.unregister()
        capture.stop()
        isCapturing = false
        state = .idle
    }

    // MARK: - activation

    /// Apply a new shortcut or activation mode without restarting.
    public func apply(configuration new: Configuration) {
        let wasListening = isCapturing
        configuration = new
        if case .failure(let error) = hotkey.rebind(to: new.hotkey) {
            note("hotkey", "could not use \(new.hotkey.displayString): \(error)")
        }
        if wasListening { Task { await endListening() } }
        note("settings", "shortcut \(new.hotkey.displayString), "
           + "\(new.activation.rawValue)")
    }

    private func handlePress() async {
        switch configuration.activation {
        case .holdToTalk:
            await beginListening()

        case .toggle:
            // The press is the whole signal; release means nothing.
            if isCapturing { await endListening() } else { await beginListening() }

        case .hybrid:
            if isCapturing {
                // Already listening, latched or not: this press stops it, and
                // the release that follows must not start anything.
                ignoreNextRelease = true
                await endListening()
            } else {
                pressedAt = Date()
                isLatched = false
                await beginListening()
            }
        }
    }

    private func handleRelease() async {
        switch configuration.activation {
        case .holdToTalk:
            await endListening()

        case .toggle:
            break

        case .hybrid:
            if ignoreNextRelease {
                ignoreNextRelease = false
                return
            }
            guard isCapturing else { return }
            let heldMillis = Int(Date().timeIntervalSince(pressedAt ?? Date()) * 1000)
            if heldMillis < configuration.tapThresholdMillis {
                // A tap, not a hold. Keep listening until the next press.
                isLatched = true
                note("hotkey", "latched after a \(heldMillis) ms tap — "
                   + "press \(configuration.hotkey.displayString) again to stop")
            } else {
                await endListening()
            }
        }
    }

    // MARK: - the dictation cycle

    private func beginListening() async {
        // Logged rather than returning in silence. When the audio graph hung
        // on a stale device, three key presses produced nothing at all in the
        // log — no error, no timing line, no clue whether the press had been
        // dropped, ignored, or swallowed. An early return that says nothing is
        // indistinguishable from a crash from the outside.
        guard !isCapturing else {
            Diagnostics.log("hotkey", "press ignored — already capturing")
            return
        }
        let pressed = Date()
        defer {
            Diagnostics.log("timing", "key down to listening: "
                + "\(Int(Date().timeIntervalSince(pressed) * 1000)) ms")
        }

        // Invariant 8: both permissions are requested here, on first use of the
        // feature that needs them, never at launch.
        // Measured explicitly rather than with a `defer`: a deferred timer
        // fires at function exit, so it reported the whole of beginListening
        // and read identically to the total below — two numbers that always
        // agree measure one thing, not two.
        let beforePermissions = Date()
        guard await AudioCapture.requestPermission() else {
            note("permission", AudioCapture.CaptureError.permissionDenied.description)
            state = .failed(AudioCapture.CaptureError.permissionDenied.description)
            return
        }
        guard AccessibilityPermission.isTrusted() || AccessibilityPermission.requestTrust() else {
            // macOS grants this asynchronously and usually wants the app
            // restarted, so a refusal on the very first press is expected
            // rather than a failure. Say so, or it reads as a bug.
            let message = "Accessibility permission is needed to type at your "
                        + "cursor. Grant it in System Settings, then press again."
            note("permission", message)
            state = .failed(message)
            return
        }

        let permissionMillis = Int(Date().timeIntervalSince(beforePermissions) * 1000)
        if permissionMillis > 50 {
            Diagnostics.log("timing", "permission checks: \(permissionMillis) ms")
        }

        segmenter.reset()
        captureStartedAt = Date()
        do {
            try capture.start { [weak self] frame in
                Task { @MainActor in self?.accept(frame: frame) }
            }
            isCapturing = true
            startUtteranceTimeout()
            note("capture", "listening")
            state = .listening
        } catch {
            note("capture", "could not start: \(error)")
            state = .failed(String(describing: error))
        }
    }

    /// Close the microphone if one utterance runs past the cap.
    ///
    /// Push-to-talk bounded this with the user's hand. Toggle and hybrid do
    /// not, so it is possible to start dictating and walk away — and a
    /// microphone nobody remembers leaving open is the single failure the
    /// privacy positioning cannot survive. The transcript is kept, not
    /// discarded: the user said those words, and throwing them away would add
    /// a second failure to the first.
    private func startUtteranceTimeout() {
        utteranceTimeout?.cancel()
        let seconds = max(10, configuration.maximumUtteranceSeconds)
        utteranceTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isCapturing else { return }
                self.note("capture", "stopped after \(seconds)s — the maximum "
                        + "for one utterance. Nothing was discarded.")
            }
            await self?.endListening()
        }
    }

    /// Whether a press is currently being served, for tests and diagnostics.
    public var isListening: Bool { isCapturing }

    private func accept(frame: [Float]) {
        // Frames already in flight when capture stopped are not part of any
        // utterance; accepting them would start a new one nobody asked for.
        guard isCapturing else { return }
        // In commit-on-release the hotkey ends the utterance, but VAD still
        // ends it early if the user stops speaking and holds the key.
        if let finished = segmenter.accept(frame: frame) {
            Diagnostics.log("vad", "silence ended the utterance while the key "
                + "was still held (\(finished.count) samples, "
                + describeDecision() + ")")
            Task { await transcribeAndType(finished) }
        }
    }

    private func endListening() async {
        // Keyed off `isCapturing`, not off `state`. This guard used to read
        // `state == .listening`, which is false whenever VAD already finished
        // an utterance during the hold — so the microphone was never closed
        // and stayed open until the app quit.
        guard isCapturing else { return }
        isLatched = false
        utteranceTimeout?.cancel()
        utteranceTimeout = nil

        // Keep listening for one buffer period. The tap delivers 100 ms at a
        // time and `stop()` discards a partially filled buffer, so releasing
        // the key used to cut the last 85 ms of speech. `isCapturing` stays
        // true across the wait on purpose: `accept(frame:)` drops frames when
        // it is false, which would throw away the very buffer being waited
        // for. A press during the drain is ignored, which is correct — the
        // previous utterance has not been handed over yet.
        try? await Task.sleep(nanoseconds: AudioCapture.drainMillis * 1_000_000)

        isCapturing = false
        capture.stop()
        guard let samples = segmenter.finish() else {
            // Two different things, and calling both "an accidental tap" was
            // wrong: holding the key through silence after VAD already
            // finished an utterance is the expected end of a normal dictation,
            // not a mistake.
            let heard = segmenter.decisionSpeechSeconds
            note("vad", heard == 0
                ? "nothing audible while the key was held — \(describeDecision())"
                : "only \(Int(heard * 1000)) ms of speech, discarded as an "
                  + "accidental tap — \(describeDecision())")
            state = .idle
            return
        }
        Diagnostics.log("vad", describeDecision())
        Diagnostics.log("capture", "captured \(samples.count) samples "
                      + "(\(String(format: "%.2f", Double(samples.count) / 16_000))s)")
        await transcribeAndType(samples)
    }

    private func transcribeAndType(_ samples: [Float]) async {
        state = .transcribing
        let captureMillis = captureStartedAt.map {
            Int(Date().timeIntervalSince($0) * 1000)
        } ?? 0
        do {
            let result = try await transcriber.transcribe(samples: samples)
            Diagnostics.log("asr", "\(result.inferenceMillis) ms -> \(result.text.debugDescription)")
            let injectionStart = Date()
            let text = postProcess(result.text)
            if text.isEmpty {
                note("inject", "nothing to type — the model returned no text")
            } else {
                try injector.type(text)
                note("inject", "typed \(text.count) characters in "
                   + "\(result.inferenceMillis) ms")
            }
            latency.record(LatencySample(
                captureMillis: captureMillis,
                inferenceMillis: result.inferenceMillis,
                injectionMillis: Int(Date().timeIntervalSince(injectionStart) * 1000),
                wasColdStart: !hasTranscribedOnce
            ))
            hasTranscribedOnce = true
            state = .idle
        } catch {
            note("error", String(describing: error))
            state = .failed(String(describing: error))
        }
    }

    /// F18: the post-correction pass runs only in commit-on-release mode.
    ///
    /// In live streaming there is nothing safe to do here — revising text that
    /// has already been typed requires backspacing, which breaks terminals and
    /// send-on-enter chat boxes.
    private func postProcess(_ text: String) -> String {
        guard configuration.mode.allowsPostCorrection else { return text }
        // The post-correction LM lands at M4. Until then this is identity, and
        // saying so is better than pretending a layer exists.
        return text
    }

    public var latencyReport: (warm: Int?, cold: Int?) {
        (latency.warmMedianMillis, latency.coldMedianMillis)
    }
}
