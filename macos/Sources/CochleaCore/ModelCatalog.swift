import Foundation

/// A downloadable model.
///
/// F21: the Homebrew formula ships the binary only; models are fetched on
/// first run with checksum verification. F23: every artifact records its
/// licence, so the licence travels with the download rather than living only
/// in a document nobody reads.
public struct ModelDescriptor: Codable, Sendable, Equatable {
    public let identifier: String
    /// HuggingFace repository id, e.g. "mlx-community/whisper-large-v3-turbo".
    public let repositoryID: String
    public let license: String
    /// Mel bins this model's encoder consumes.
    ///
    /// §1.2 binds a stored mel feature to the model that produced it, so this
    /// is part of the model's identity, not a tuning parameter. large-v3 and
    /// its turbo derivative use 128; earlier Whisper variants use 80.
    public let melBins: Int
    public let approximateBytes: Int64

    /// SHA-256 digests keyed by filename, when known and reviewed.
    ///
    /// Empty means the digests are resolved from the provider at download
    /// time — weaker, and the app says so. See docs/DECISIONS.md D2.
    public let pinnedSHA256: [String: String]

    public var isPinned: Bool { !pinnedSHA256.isEmpty }

    public init(identifier: String, repositoryID: String, license: String,
                melBins: Int, approximateBytes: Int64,
                pinnedSHA256: [String: String] = [:]) {
        self.identifier = identifier
        self.repositoryID = repositoryID
        self.license = license
        self.melBins = melBins
        self.approximateBytes = approximateBytes
        self.pinnedSHA256 = pinnedSHA256
    }
}

public enum ModelCatalog {

    /// The default, decided in docs/DECISIONS.md D1.
    ///
    /// Whisper rather than SenseVoice because contextual biasing (M2, the
    /// layer that pays off first) needs an autoregressive decode loop to bias,
    /// because the largest audience gains nothing from SenseVoice's Mandarin
    /// advantage, and because Whisper is MIT and so does not put F23's licence
    /// audit on the critical path. Turbo rather than plain large-v3 because
    /// F18's sub-1s budget is spent in the decoder.
    public static let whisperLargeV3Turbo = ModelDescriptor(
        identifier: "whisper-large-v3-turbo",
        repositoryID: "mlx-community/whisper-large-v3-turbo",
        license: "MIT",
        melBins: 128,
        approximateBytes: 1_600_000_000,
        // Empty: this build could not reach the provider to obtain real
        // digests, and inventing one would make every download fail as a
        // checksum mismatch that reads like corruption. Populate with
        // scripts/pin-model.sh before distributing. (D2)
        pinnedSHA256: [:]
    )

    /// A smaller default for constrained machines, per F19's note about
    /// offering a smaller model rather than making everyone pay the RAM.
    public static let whisperSmall = ModelDescriptor(
        identifier: "whisper-small",
        repositoryID: "mlx-community/whisper-small-mlx",
        license: "MIT",
        melBins: 80,
        approximateBytes: 500_000_000,
        pinnedSHA256: [:]
    )

    public static let known: [ModelDescriptor] = [whisperLargeV3Turbo, whisperSmall]

    public static let `default` = whisperLargeV3Turbo

    public static func descriptor(for identifier: String) -> ModelDescriptor? {
        known.first { $0.identifier == identifier }
    }

    /// Every model shipped must record its licence (F23).
    public static var licenseSummary: String {
        known.map { "\($0.identifier): \($0.license)" }.joined(separator: "\n")
    }
}
