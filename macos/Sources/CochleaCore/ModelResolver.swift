import Foundation

/// Resolves a model's files and their digests from the provider.
///
/// See docs/DECISIONS.md D2. Pinned digests are verified against a value
/// committed to the repository and reviewable in a diff; resolved digests are
/// trust-on-first-use, because whoever controls the API controls both the file
/// and the digest it is checked against. The difference is surfaced, not
/// hidden.
public struct RemoteFile: Sendable, Equatable {
    public let filename: String
    public let url: URL
    public let sha256: String?
    public let sizeBytes: Int64
    /// True when `sha256` came from the repository rather than the provider.
    public let isPinned: Bool
}

public enum ModelResolutionError: Error, CustomStringConvertible {
    case providerUnreachable(underlying: String)
    case malformedResponse
    case noWeightsFound(repository: String)

    public var description: String {
        switch self {
        case .providerUnreachable(let underlying):
            return "could not reach the model provider: \(underlying)"
        case .malformedResponse:
            return "the model provider returned something this build cannot parse"
        case .noWeightsFound(let repository):
            return "no weight files found in \(repository)"
        }
    }
}

public actor ModelResolver {

    private let session: URLSession
    /// Emitted when a download will proceed on a resolved rather than pinned
    /// digest, so the weaker guarantee is visible rather than silent.
    public static let unpinnedWarning = """
        This model's checksum was resolved from the provider rather than pinned \
        in cochlea. That is trust-on-first-use: it verifies the bytes you \
        received match what the provider says, but not that the provider is \
        serving what was reviewed. Run scripts/pin-model.sh to pin it.
        """

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The files needed to run a model, with a digest for each.
    ///
    /// The file list is resolved rather than hardcoded: filenames differ
    /// between conversions and a wrong guess fails at download time with a
    /// confusing 404.
    public func resolve(_ model: ModelDescriptor) async throws -> [RemoteFile] {
        let api = URL(string:
            "https://huggingface.co/api/models/\(model.repositoryID)?blobs=true")!
        let data: Data
        do {
            (data, _) = try await session.data(from: api)
        } catch {
            throw ModelResolutionError.providerUnreachable(
                underlying: String(describing: error))
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let siblings = root["siblings"] as? [[String: Any]]
        else { throw ModelResolutionError.malformedResponse }

        var files: [RemoteFile] = []
        for entry in siblings {
            guard let filename = entry["rfilename"] as? String else { continue }
            guard Self.isNeeded(filename) else { continue }

            let resolvedDigest = Self.providerDigest(from: entry)
            let size = (entry["size"] as? NSNumber)?.int64Value
                ?? ((entry["lfs"] as? [String: Any])?["size"] as? NSNumber)?.int64Value
                ?? 0
            let pinned = model.pinnedSHA256[filename]?.lowercased()
            let url = URL(string:
                "https://huggingface.co/\(model.repositoryID)/resolve/main/\(filename)")!
            files.append(RemoteFile(
                filename: filename,
                url: url,
                sha256: pinned ?? resolvedDigest,
                sizeBytes: size,
                isPinned: pinned != nil
            ))
        }
        guard files.contains(where: { Self.isWeights($0.filename) }) else {
            throw ModelResolutionError.noWeightsFound(repository: model.repositoryID)
        }
        return files
    }

    /// The SHA-256 an LFS-tracked file is published under, if the provider
    /// gives one.
    ///
    /// Two HuggingFace endpoints spell the same value differently: the
    /// `?blobs=true` model endpoint this resolver calls puts it in
    /// `lfs.sha256`, while `paths-info` puts it in `lfs.oid`. Accept either,
    /// so a change of endpoint is not a silent loss of verification.
    ///
    /// The *top-level* `oid` is deliberately not consulted. For a file git
    /// stores directly — `config.json` in every mlx-community Whisper repo —
    /// it is the git blob SHA-1: 40 hex characters, not 64, and not a digest
    /// of the file's contents at all. Reading it would turn every download
    /// into a checksum mismatch that reads like file corruption, which is the
    /// precise failure D2 refused to ship a fabricated digest for. The width
    /// check is what keeps that from happening.
    ///
    /// A non-LFS file therefore has no resolvable digest from any provider
    /// endpoint, and can only be verified by being pinned. See D4.
    static func providerDigest(from entry: [String: Any]) -> String? {
        guard let lfs = entry["lfs"] as? [String: Any] else { return nil }
        guard let candidate = (lfs["sha256"] as? String) ?? (lfs["oid"] as? String)
        else { return nil }
        guard isSHA256(candidate) else { return nil }
        return candidate.lowercased()
    }

    /// 64 hex characters. Deliberately strict: the point is to reject a SHA-1.
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    static func isWeights(_ filename: String) -> Bool {
        filename.hasSuffix(".safetensors") || filename.hasSuffix(".npz")
    }

    static func isNeeded(_ filename: String) -> Bool {
        if filename.contains("/") { return false }        // no nested variants
        return isWeights(filename)
            || filename == "config.json"
            || filename == "tokenizer.json"
            || filename == "preprocessor_config.json"
    }
}
