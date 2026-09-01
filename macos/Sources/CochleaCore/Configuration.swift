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

    /// How the hotkey starts and stops dictation.
    ///
    /// Push-to-talk was the only option and it is wrong for long input: holding
    /// a chord through a three-minute paragraph is its own kind of work. Toggle
    /// fixes that and introduces a different problem, which is that the
    /// microphone can be left open indefinitely — see `maximumUtteranceSeconds`.
    public enum Activation: String, Codable, Sendable, CaseIterable {
        /// Hold the key, speak, release. What M0 shipped.
        case holdToTalk
        /// Press once to start, press again to stop.
        case toggle
        /// Hold it and it behaves like push-to-talk; tap it and it latches
        /// until the next tap. One binding, both behaviours, no mode setting to
        /// find — which is what most dictation apps settle on.
        case hybrid

        public var explanation: String {
            switch self {
            case .holdToTalk:
                return "Hold the shortcut while you speak. Releasing it ends the utterance."
            case .toggle:
                return "Press once to start, press again to stop."
            case .hybrid:
                return "Hold to talk, or tap once to keep listening until you tap again."
            }
        }
    }

    public var activation: Activation = .hybrid

    /// Below this, a press counts as a tap rather than a hold.
    ///
    /// Only consulted in `.hybrid`. Long enough that a deliberate short
    /// utterance is not mistaken for a tap, short enough that tapping does not
    /// feel like waiting.
    public var tapThresholdMillis: Int = 400

    /// A hard bound on how long the microphone stays open in one utterance.
    ///
    /// Toggle and hybrid make it possible to walk away with dictation running,
    /// which push-to-talk made physically impossible. This is the answer to
    /// that, and it is not optional: an open microphone nobody remembers is
    /// exactly the failure the privacy positioning cannot survive. The user is
    /// told when it fires rather than finding a silently truncated transcript.
    public var maximumUtteranceSeconds: Int = 300

    /// Defaults to streaming.
    ///
    /// The thing it gives up is the M4 post-correction pass, which does not
    /// exist yet, so today the choice costs nothing and removes a wait that
    /// grows with how much you say — under latch activation that is minutes of
    /// staring at an empty cursor. Revisit when M4 lands and the trade becomes
    /// real; until then, defaulting to the mode with no downside is the honest
    /// setting. See DECISIONS D9.
    public var mode: Mode = .liveStreaming
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

    /// Force a language instead of letting Whisper detect one.
    ///
    /// `nil` detects per 30-second window, which is what P1's code-switching
    /// needs and what a monolingual user pays for: detection reads a short or
    /// clipped utterance as whatever language it most resembles, and a wrong
    /// guess mistranscribes the whole window rather than a word of it. An
    /// ISO code here ("en", "zh") removes that failure for anyone who does not
    /// need the switching.
    public var language: String?

    /// The dictation shortcut. Stored so it survives a rebuild, which the
    /// hardcoded Control-Option-D did not.
    public var hotkey: HotkeyBinding = .default

    /// Opens the last utterance for correction.
    public var fixHotkey: HotkeyBinding = .defaultFix

    /// How long after typing the app will still offer to take text back.
    ///
    /// It cannot see the user's document (SPEC §1 rules out watching text
    /// fields through the Accessibility API), so it cannot know whether the
    /// cursor has moved. This is a bound on how wrong it can be rather than a
    /// check that it is right: a correction offered ten minutes later is being
    /// made somewhere else entirely, and deleting characters there deletes the
    /// wrong ones. Recording the correction is always offered; only taking the
    /// text back expires.
    public var replaceWindowSeconds: Int = 120

    /// F18 latency budget, in milliseconds, for a typical utterance.
    public var latencyBudgetMillis: Int = 1000

    /// Deliberately **not** part of the encoded form. See `CodingKeys`.
    public var home: URL

    /// Everything except `home`.
    ///
    /// `home` is where `config.json` was found, so decoding it *from*
    /// `config.json` can only ever produce a value that contradicts the path
    /// the file was just loaded from. Worse, it makes the file
    /// machine-specific: a config copied from a README or another Mac points
    /// the app at a directory that does not exist, and the app dies at launch
    /// creating it. That happened. The config carries preferences; where it
    /// lives is not one of them.
    private enum CodingKeys: String, CodingKey {
        case mode, modelIdentifier, keepModelResident
        case acousticRetentionEnabled, latencyBudgetMillis, language
        case activation, tapThresholdMillis, maximumUtteranceSeconds
        case hotkey, fixHotkey, replaceWindowSeconds
    }

    public init(from decoder: Decoder) throws {
        self.init()                     // home from COCHLEA_HOME, or the default
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Every key optional: a config written by an older or newer build, or
        // hand-edited down to the one line someone cared about, should apply
        // what it does say rather than being discarded whole.
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? mode
        modelIdentifier = try values.decodeIfPresent(
            String.self, forKey: .modelIdentifier) ?? modelIdentifier
        keepModelResident = try values.decodeIfPresent(
            Bool.self, forKey: .keepModelResident) ?? keepModelResident
        acousticRetentionEnabled = try values.decodeIfPresent(
            Bool.self, forKey: .acousticRetentionEnabled) ?? acousticRetentionEnabled
        latencyBudgetMillis = try values.decodeIfPresent(
            Int.self, forKey: .latencyBudgetMillis) ?? latencyBudgetMillis
        language = try values.decodeIfPresent(String.self, forKey: .language)
        activation = try values.decodeIfPresent(
            Activation.self, forKey: .activation) ?? activation
        tapThresholdMillis = try values.decodeIfPresent(
            Int.self, forKey: .tapThresholdMillis) ?? tapThresholdMillis
        maximumUtteranceSeconds = try values.decodeIfPresent(
            Int.self, forKey: .maximumUtteranceSeconds) ?? maximumUtteranceSeconds
        hotkey = try values.decodeIfPresent(HotkeyBinding.self, forKey: .hotkey) ?? hotkey
        fixHotkey = try values.decodeIfPresent(
            HotkeyBinding.self, forKey: .fixHotkey) ?? fixHotkey
        replaceWindowSeconds = try values.decodeIfPresent(
            Int.self, forKey: .replaceWindowSeconds) ?? replaceWindowSeconds
    }

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
