import AVFoundation
import CochleaCore
import Foundation

/// Microphone capture, converted to the 16 kHz mono float the ASR expects.
///
/// Invariant 8: the microphone permission is requested when the user first
/// presses the dictation hotkey, never at launch.
public final class AudioCapture {

    public enum CaptureError: Error, CustomStringConvertible {
        case permissionDenied
        case converterUnavailable

        public var description: String {
            switch self {
            case .permissionDenied:
                return "microphone access was denied; grant it in System Settings "
                     + "> Privacy & Security > Microphone"
            case .converterUnavailable:
                return "could not build a converter to 16 kHz mono"
            }
        }
    }

    public static let targetSampleRate: Double = 16_000

    /// Replaced, not reused, whenever the hardware changes underneath it.
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private var onFrame: (([Float]) -> Void)?
    private var observer: NSObjectProtocol?

    /// Set from the notification queue, read on the main actor.
    private let stateLock = NSLock()
    private var _needsRebuild = false
    private var needsRebuild: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _needsRebuild }
        set { stateLock.lock(); _needsRebuild = newValue; stateLock.unlock() }
    }

    public init() {
        // swiftlint:disable:next force_unwrapping
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: Self.targetSampleRate,
                                     channels: 1,
                                     interleaved: false)!

        // AVAudioEngine binds to the input device it was built against. When
        // that device goes away — AirPods connecting, an interface unplugged —
        // macOS posts this and expects the graph rebuilt. Nothing listened, so
        // the engine kept a reference to hardware that no longer existed and
        // `start()` blocked forever on the next press. Because that call runs
        // on the main actor, the whole app went with it: the hotkey still
        // logged key-down from the Carbon handler while every task queued
        // behind a main actor that was never coming back.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.needsRebuild = true
            Diagnostics.log("audio", "input device changed; the graph will be "
                          + "rebuilt on the next press")
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Whether a device change is pending. Readable so the wiring can be
    /// tested on a machine with no microphone, which is every CI runner.
    public var hasPendingRebuild: Bool { needsRebuild }

    /// Throw away the graph and build a clean one.
    ///
    /// Cheaper than it looks and much safer than reusing: the expensive part
    /// of the first `inputNode` access is the audio HAL warming up, which is
    /// process-wide and survives a new engine.
    private func rebuildIfNeeded() {
        guard needsRebuild else { return }
        needsRebuild = false
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
        converter = nil
        Diagnostics.log("audio", "graph rebuilt for the current input device")
    }

    /// Whether the microphone is already granted. Never prompts, so it is
    /// safe to call at launch under invariant 8 — reporting a permission is
    /// not requesting one.
    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Pay the audio graph's one-time setup cost at launch instead of on the
    /// first hotkey press.
    ///
    /// Measured: the first `inputNode` access costs ~190-240 ms and every
    /// access after it is free. On the first press of a session that lands
    /// between the key going down and the microphone opening, which is time
    /// the user is already speaking into — the first word of the first
    /// utterance is simply lost. Doing it at launch is the same fix F19
    /// applies to the model, for the same reason.
    ///
    /// This does **not** open the microphone: no engine is started, no
    /// recording indicator lights, and no permission is requested — it is
    /// skipped entirely unless permission has already been granted, so
    /// invariant 8 holds. Reporting is not requesting.
    @discardableResult
    public func prewarm() -> Bool {
        guard Self.hasPermission else { return false }
        rebuildIfNeeded()
        let began = Date()
        _ = engine.inputNode.outputFormat(forBus: 0)
        Diagnostics.log("audio", "graph prewarmed in "
            + "\(Int(Date().timeIntervalSince(began) * 1000)) ms "
            + "(microphone not opened)")
        return true
    }

    /// Asks for microphone access. Call this from the hotkey handler.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(onFrame: @escaping ([Float]) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.permissionDenied
        }
        self.onFrame = onFrame
        rebuildIfNeeded()

        // Timed per phase: audio taken before the microphone is actually open
        // is audio the user spoke and lost, so any delay here clips the start
        // of the utterance. Measured in isolation this whole sequence is about
        // 265 ms; if it is seconds inside the app, the cost is somewhere these
        // marks will name rather than somewhere anyone has to guess.
        let began = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(began) * 1000) }

        let input = engine.inputNode
        let afterNode = elapsed()
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter
        let afterConverter = elapsed()

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer) else { return }
            self.onFrame?(converted)
        }
        let afterTap = elapsed()
        engine.prepare()
        try engine.start()
        Diagnostics.log("audio", "open in \(elapsed()) ms "
            + "(node \(afterNode), converter \(afterConverter - afterNode), "
            + "tap \(afterTap - afterConverter), engine \(elapsed() - afterTap)) "
            + "@ \(Int(inputFormat.sampleRate)) Hz")
    }

    public func stop() {
        // Guarded: after the input device disappears, touching the old node
        // is exactly what hangs, and stopping is the one path that must
        // always work — it is how the microphone gets closed.
        if !needsRebuild {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } else {
            engine.stop()
        }
        onFrame = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
