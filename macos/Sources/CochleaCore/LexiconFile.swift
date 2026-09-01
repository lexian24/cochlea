import Foundation

/// What dictation is biased towards, as the app sees it.
///
/// Read straight from `~/.cochlea/lexicon.json` rather than through the
/// `dictate` helper. The file is small, the app only needs to display and
/// prune it, and a subprocess per settings-window keystroke would be absurd —
/// but the deeper reason is that the format is deliberately a plain, readable
/// file (DECISIONS D10). A user who wants to check what was taken from their
/// messages can open it; if the app needed a tool to read it, that claim would
/// be weaker than it sounds.
///
/// Writing is confined to removal. Everything that *adds* an entry runs
/// through `dictate`, because admission enforces F5 and F2 and duplicating
/// those rules here would mean two implementations that must agree forever.
public struct LexiconFile: Codable, Sendable {

    public struct Entry: Codable, Sendable, Identifiable, Hashable {
        public var term: String
        public var boost: Double
        public var hits: Int
        public var rejections: Int
        public var lastUsedAt: Double

        public var id: String { term }

        /// A phrase rather than a single word, which is the case biasing is
        /// actually good at and worth showing differently.
        public var isPhrase: Bool { term.contains(" ") }

        enum CodingKeys: String, CodingKey {
            case term, boost, hits, rejections
            case lastUsedAt = "last_used_at"
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            term = try values.decode(String.self, forKey: .term)
            // Everything but the term is optional: a hand-edited file, which
            // the format exists to permit, will not carry the bookkeeping.
            boost = try values.decodeIfPresent(Double.self, forKey: .boost) ?? 1.0
            hits = try values.decodeIfPresent(Int.self, forKey: .hits) ?? 0
            rejections = try values.decodeIfPresent(Int.self, forKey: .rejections) ?? 0
            lastUsedAt = try values.decodeIfPresent(Double.self, forKey: .lastUsedAt) ?? 0
        }

        public init(term: String, boost: Double = 1.5, hits: Int = 0,
                    rejections: Int = 0, lastUsedAt: Double = 0) {
            self.term = term
            self.boost = boost
            self.hits = hits
            self.rejections = rejections
            self.lastUsedAt = lastUsedAt
        }
    }

    public var version: Int = 1
    public var language: String = "en"
    public var entries: [Entry] = []
    public var canonical: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "en"
        entries = try values.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        canonical = try values.decodeIfPresent([String: String].self,
                                               forKey: .canonical) ?? [:]
    }

    /// Read the lexicon, or an empty one when there is nothing to read.
    ///
    /// A missing file is the normal state before the first import, and a
    /// corrupt one must not stop the settings window opening. Both give an
    /// empty lexicon, which is exactly what the decoder does with them too.
    public static func load(from url: URL) -> LexiconFile {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LexiconFile.self, from: data)
        else { return LexiconFile() }
        return decoded
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        // Terms lifted out of the user's own messages. `dictate` writes 0600
        // and an atomic replace does not carry permissions across, so this
        // must be set again or the app would quietly widen them.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }

    public mutating func remove(_ term: String) {
        entries.removeAll { $0.term == term }
    }

    /// Entries that have won most often first, then alphabetically.
    ///
    /// Hits are what tell an entry that is earning its place from one that is
    /// only costing F2 headroom, so they are what the list should be ordered
    /// by — not by when it was added, which says nothing about whether it
    /// works.
    public var sorted: [Entry] {
        entries.sorted { ($0.hits, $1.term) > ($1.hits, $0.term) }
    }

    public var phraseCount: Int { entries.filter(\.isPhrase).count }
}

extension LexiconFile {
    enum CodingKeys: String, CodingKey {
        case version, language, entries, canonical
    }

    /// Where the file lives, given the configuration's home.
    public static func url(for configuration: Configuration) -> URL {
        configuration.home.appendingPathComponent("lexicon.json")
    }
}
