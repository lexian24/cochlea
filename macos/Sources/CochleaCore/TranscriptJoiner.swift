import Foundation

/// Decides what separator, if any, goes between two committed segments.
///
/// Streaming types each segment as it is recognised, so the space that used to
/// fall naturally inside one transcript now has to be reconstructed at the
/// boundary. Getting it wrong is visible in every single sentence: no
/// separator gives `helloworld`, an unconditional one gives `hello ,` and
/// `你好 世界`.
///
/// The joiner holds only what it needs to make that call — the tail of the
/// previous segment — and never the transcript itself. Nothing here can
/// revise text that has already been typed; F18 forbids backspacing.
public struct TranscriptJoiner: Sendable {

    /// The last character committed, which is all the context a separator
    /// decision needs.
    private var previousTail: Character?

    public init() {}

    /// The exact string to type for `segment`, or `nil` if there is nothing.
    ///
    /// Whisper returns segments with inconsistent leading and trailing
    /// whitespace, so the decision is made on trimmed text and the separator
    /// added deliberately rather than inherited from whatever the model
    /// happened to emit.
    public mutating func join(_ segment: String) -> String? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        defer { previousTail = trimmed.last }
        guard let tail = previousTail else { return trimmed }
        return Self.needsSpace(after: tail, before: first) ? " " + trimmed : trimmed
    }

    /// Forget the previous segment, as when a new dictation session begins at
    /// a cursor position that has nothing to do with the last one.
    public mutating func reset() { previousTail = nil }

    /// Whether a space belongs between two adjacent characters.
    ///
    /// Three cases say no. Scripts that do not use interword spacing — the
    /// CJK half of P1's code-switching — must not gain one; a segment opening
    /// with punctuation is finishing the previous clause, not starting a new
    /// one; and whitespace that survived trimming is already a separator.
    public static func needsSpace(after tail: Character, before head: Character) -> Bool {
        if tail.isWhitespace || head.isWhitespace { return false }
        if isTrailingPunctuation(head) { return false }
        if isUnspaced(tail) || isUnspaced(head) { return false }
        return true
    }

    /// Punctuation that attaches to the word before it.
    ///
    /// Closing brackets and quotes are deliberately absent: an opening quote
    /// is the same character in ASCII, and guessing wrong on `"` is worse
    /// than the missing space it would fix.
    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        ",.!?;:%)]}…".contains(character)
    }

    /// A character from a script written without spaces between words.
    ///
    /// Hangul is excluded on purpose: Korean is written in this block's
    /// neighbourhood but does space its words, so treating it like Chinese
    /// would run every sentence together.
    private static func isUnspaced(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F,   // CJK punctuation: 。，、！？
                 0x3040...0x30FF,   // Hiragana and Katakana
                 0x3400...0x4DBF,   // CJK extension A
                 0x4E00...0x9FFF,   // CJK unified ideographs
                 0xF900...0xFAFF,   // compatibility ideographs
                 0xFF00...0xFF65:   // fullwidth forms
                return true
            default:
                return false
            }
        }
    }
}
