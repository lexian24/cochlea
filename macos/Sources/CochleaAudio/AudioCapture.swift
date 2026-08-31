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

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer) else { return }
            self.onFrame?(converted)
        }
        engine.prepare()
        try engine.start()
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
