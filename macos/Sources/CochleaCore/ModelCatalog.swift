import Foundation

/// A downloadable model, its checksum, and its licence.
///
/// F21: the Homebrew formula ships the binary only; models are fetched on
/// first run with checksum verification. F23: every shipped artifact records
/// its licence, so the licence travels with the download rather than living
/// only in a document nobody reads.
public struct ModelDescriptor: Codable, Sendable, Equatable {
    public let identifier: String
    public let url: URL
    /// Lowercase hex SHA-256 of the downloaded file.
    public let sha256: String
    public let sizeBytes: Int64
    public let license: String
    /// Mel bins this model's encoder consumes. Recorded because §1.2 binds a
    /// stored mel feature to the model that produced it.
    public let melBins: Int

    public init(identifier: String, url: URL, sha256: String,
                sizeBytes: Int64, license: String, melBins: Int) {
        self.identifier = identifier
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.license = license
        self.melBins = melBins
    }
}

public enum ModelCatalog {
    /// Empty on purpose.
    ///
    /// SPEC §7 leaves the default base model open pending an M0 benchmark of
    /// Whisper turbo against SenseVoice-Small, and F23 requires a licence audit
    /// before any weight is distributed. Publishing a URL and checksum here
    /// before either is done would be inventing both answers. Populate this
    /// once the benchmark is run and the licences are recorded in
    /// LICENSES-MODELS.md.
    public static let known: [ModelDescriptor] = []

    public static func descriptor(for identifier: String) -> ModelDescriptor? {
        known.first { $0.identifier == identifier }
    }
}
