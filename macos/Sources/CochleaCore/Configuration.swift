import Foundation

/// Where cochlea keeps its data, and how it behaves at runtime.
///
/// Defaults encode SPEC invariants rather than preferences: acoustic retention
/// is off (invariant 7), and the post-correction pass is disabled in live
/// streaming mode (F18).
public struct Configuration: Codable, Sendable {

    /// F18: the two modes differ in what they can safely do, not just in feel.
    public enum Mode: String, Codable, Sendable {
        /// Text is committed when the hotkey is released. Post-correction can
        /// run, because nothing has been typed yet.
        case commitOnRelease
        /// Text is typed as it is recognised. Post-correction is disabled: it
        /// cannot revise already-typed text without backspacing, which breaks
        /// terminals and send-on-enter chat boxes.
        case liveStreaming

        public var allowsPostCorrection: Bool { self == .commitOnRelease }
    }

    public var mode: Mode = .commitOnRelease
    /// Sourced from the catalog rather than written out, because a literal
    /// here drifted: it read "whisper-turbo", which matches no descriptor, so
    /// `ModelCatalog.descriptor(for:)` would have returned nil the moment
    /// anything resolved it. Nothing read it yet, so it never fired.
    public var modelIdentifier: String = ModelCatalog.default.identifier

    /// F19: hold the model in memory and warm it at launch. A multi-second
    /// delay on the first hotkey press reads as broken.
    public var keepModelResident: Bool = true

    /// Invariant 7. Flipping this is a user action, never a default.
    public var acousticRetentionEnabled: Bool = false

    /// F18 latency budget, in milliseconds, for a typical utterance.
    public var latencyBudgetMillis: Int = 1000

    public var home: URL

    public init(home: URL? = nil) {
        if let home {
            self.home = home
        } else if let override = ProcessInfo.processInfo.environment["COCHLEA_HOME"] {
            self.home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.home = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".cochlea", isDirectory: true)
        }
    }

    public var modelsDirectory: URL { home.appendingPathComponent("models", isDirectory: true) }
    public var configFile: URL { home.appendingPathComponent("config.json") }

    public func ensureHomeExists() throws {
        try FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true)
    }

    public static func load(from url: URL) throws -> Configuration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Configuration.self, from: data)
    }

    public func save() throws {
        try ensureHomeExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: configFile, options: .atomic)
    }
}
