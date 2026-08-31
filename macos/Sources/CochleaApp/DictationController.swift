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

    private let configuration: Configuration
    private let capture = AudioCapture()
    private let injector = TextInjector()
    private let hotkey = HotkeyMonitor()
    private let latency = LatencyRecorder()
    private var segmenter = Segmenter()
    private var transcriber: Transcriber
    private var hasTranscribedOnce = false
    private var captureStartedAt: Date?

    public init(configuration: Configuration, transcriber: Transcriber) {
        self.configuration = configuration
        self.transcriber = transcriber
    }

    public func start() throws {
        hotkey.onPress = { [weak self] in Task { @MainActor in await self?.beginListening() } }
        hotkey.onRelease = { [weak self] in Task { @MainActor in await self?.endListening() } }
        try hotkey.register()

        // F19: warm the model at launch so the first press does not pay load
        // time. Failure here is not fatal; it surfaces on first use instead.
        if configuration.keepModelResident {
            Task.detached { [transcriber] in try? await transcriber.warmUp() }
        }
    }

    public func stop() {
        try? hotkey.unregister()
        capture.stop()
        state = .idle
    }

    // MARK: - the dictation cycle

    private func beginListening() async {
        guard state == .idle else { return }

        // Invariant 8: both permissions are requested here, on first use of the
        // feature that needs them, never at launch.
        guard await AudioCapture.requestPermission() else {
            state = .failed(AudioCapture.CaptureError.permissionDenied.description)
            return
        }
        guard AccessibilityPermission.isTrusted() || AccessibilityPermission.requestTrust() else {
            state = .failed("Accessibility permission is needed to type at your cursor.")
            return
        }

        segmenter.reset()
        captureStartedAt = Date()
        do {
            try capture.start { [weak self] frame in
                Task { @MainActor in self?.accept(frame: frame) }
            }
            state = .listening
        } catch {
            state = .failed(String(describing: error))
        }
    }

    private func accept(frame: [Float]) {
        // In commit-on-release the hotkey ends the utterance, but VAD still
        // ends it early if the user stops speaking and holds the key.
        if let finished = segmenter.accept(frame: frame) {
            Task { await transcribeAndType(finished) }
        }
    }

    private func endListening() async {
        guard state == .listening else { return }
        capture.stop()
        guard let samples = segmenter.finish() else {
            state = .idle          // too short: an accidental tap
            return
        }
        await transcribeAndType(samples)
    }

    private func transcribeAndType(_ samples: [Float]) async {
        state = .transcribing
        let captureMillis = captureStartedAt.map {
            Int(Date().timeIntervalSince($0) * 1000)
        } ?? 0
        do {
            let result = try await transcriber.transcribe(samples: samples)
            let injectionStart = Date()
            let text = postProcess(result.text)
            if !text.isEmpty {
                try injector.type(text)
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
