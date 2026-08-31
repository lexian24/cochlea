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

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private var onFrame: (([Float]) -> Void)?

    public init() {
        // swiftlint:disable:next force_unwrapping
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: Self.targetSampleRate,
                                     channels: 1,
                                     interleaved: false)!
    }

    /// Whether the microphone is already granted. Never prompts, so it is
    /// safe to call at launch under invariant 8 — reporting a permission is
    /// not requesting one.
    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
