import Foundation

/// The pipe end of the sidecar protocol: newline-delimited JSON, with raw
/// audio following the request line it belongs to.
///
/// Blocking reads and writes on a private serial queue, bridged to `async`.
/// The obvious alternative — doing the I/O inside the actor — would block a
/// cooperative thread for the whole of a multi-second transcription, and the
/// concurrency this would buy is concurrency the protocol does not have:
/// push-to-talk means exactly one utterance is ever in flight.
final class SidecarIO: @unchecked Sendable {

    static let protocolVersion = 1

    private let queue = DispatchQueue(label: "com.cochlea.sidecar.io")
    private var input: FileHandle?
    private var output: FileHandle?
    /// Bytes read past the end of the last message. A pipe read returns
    /// whatever happens to be buffered, which is regularly more than one line.
    private var pending = Data()

    func attach(input: FileHandle, output: FileHandle) {
        queue.sync {
            self.input = input
            self.output = output
            self.pending = Data()
        }
    }

    func close() {
        queue.sync {
            try? input?.close()
            try? output?.close()
            input = nil
            output = nil
        }
    }

    /// 16 kHz mono little-endian float32 — what `AudioCapture` already produces
    /// and what Whisper's frontend consumes, so nothing resamples in between.
    static func encode(samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func request(_ message: [String: Any], payload: Data?) async throws -> [String: Any] {
        try await perform {
            try self.writeSync(message: message, payload: payload)
            return try self.readMessageSync()
        }
    }

    func readMessage() async throws -> [String: Any] {
        try await perform { try self.readMessageSync() }
    }

    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    // MARK: - on the queue

    private func writeSync(message: [String: Any], payload: Data?) throws {
        guard let output else { throw SidecarError.closed }
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        try output.write(contentsOf: line)
        if let payload, !payload.isEmpty {
            try output.write(contentsOf: payload)
        }
    }

    private func readMessageSync() throws -> [String: Any] {
        guard let input else { throw SidecarError.closed }
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = try JSONSerialization.jsonObject(with: line)
                        as? [String: Any] else {
                    throw SidecarError.backend("sidecar sent a non-object message")
                }
                if object["ok"] as? Bool == false {
                    throw SidecarError.backend(
                        object["error"] as? String ?? "sidecar reported a failure")
                }
                return object
            }
            let chunk = input.availableData
            // Empty means EOF: the child exited. Its reason went to stderr.
            if chunk.isEmpty { throw SidecarError.closed }
            pending.append(chunk)
        }
    }
}
