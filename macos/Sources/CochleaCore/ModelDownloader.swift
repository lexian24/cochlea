import CryptoKit
import Foundation

public enum ModelDownloadError: Error, CustomStringConvertible {
    case unknownModel(String)
    case checksumMismatch(expected: String, actual: String)
    case serverDoesNotSupportResume
    case incomplete(received: Int64, expected: Int64)

    public var description: String {
        switch self {
        case .unknownModel(let id):
            return "no descriptor for model \(id); populate ModelCatalog first"
        case .checksumMismatch(let expected, let actual):
            return "checksum mismatch: expected \(expected), got \(actual). "
                 + "The download was not used."
        case .serverDoesNotSupportResume:
            return "server ignored a Range request; restart the download"
        case .incomplete(let received, let expected):
            return "incomplete download: \(received) of \(expected) bytes"
        }
    }
}

/// Fetches a model on first run, resumably, and refuses to install anything
/// whose checksum does not match (F21).
public actor ModelDownloader {
    public typealias ProgressHandler = @Sendable (Double) -> Void

    private let session: URLSession
    private let fileManager = FileManager.default

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func localURL(for model: ModelDescriptor,
                         in directory: URL) -> URL {
        directory.appendingPathComponent("\(model.identifier).bin")
    }

    /// Returns the on-disk URL, downloading only if it is missing or corrupt.
    public func ensureAvailable(_ model: ModelDescriptor,
                                in directory: URL,
                                progress: ProgressHandler? = nil) async throws -> URL {
        let destination = localURL(for: model, in: directory)
        if fileManager.fileExists(atPath: destination.path),
           try Self.sha256(ofFileAt: destination) == model.sha256 {
            return destination
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try await download(model, to: destination, progress: progress)
        let actual = try Self.sha256(ofFileAt: destination)
        guard actual == model.sha256 else {
            // Never leave an unverified blob where a model is expected.
            try? fileManager.removeItem(at: destination)
            throw ModelDownloadError.checksumMismatch(expected: model.sha256, actual: actual)
        }
        return destination
    }

    /// Downloads to `<destination>.part`, resuming if a partial file exists,
    /// and moves into place only after the bytes are all there.
    private func download(_ model: ModelDescriptor,
                          to destination: URL,
                          progress: ProgressHandler?) async throws {
        let partial = destination.appendingPathExtension("part")
        var existing: Int64 = 0
        if let attrs = try? fileManager.attributesOfItem(atPath: partial.path),
           let size = attrs[.size] as? NSNumber {
            existing = size.int64Value
        }

        var request = URLRequest(url: model.url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let resuming = existing > 0 && http?.statusCode == 206
        if existing > 0 && !resuming {
            // Server sent the whole file instead of the requested range.
            try? fileManager.removeItem(at: partial)
            existing = 0
        }

        if !fileManager.fileExists(atPath: partial.path) {
            fileManager.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var written = existing
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress?(Double(written) / Double(max(model.sizeBytes, 1)))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        try handle.close()
        progress?(1.0)

        guard written >= model.sizeBytes else {
            throw ModelDownloadError.incomplete(received: written, expected: model.sizeBytes)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partial, to: destination)
    }

    /// Streaming SHA-256 so a 1.6 GB model is never held in memory at once.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
