import AppKit
import CoreGraphics
import Foundation

/// Types text at the cursor in whatever application is frontmost.
///
/// Synthesises Unicode key events rather than using the pasteboard: a
/// pasteboard write clobbers whatever the user had copied, and restoring it is
/// racy. Chunking exists because `keyboardSetUnicodeString` truncates long
/// strings.
public final class TextInjector {

    public enum InjectionError: Error, CustomStringConvertible {
        case notTrusted
        case eventCreationFailed

        public var description: String {
            switch self {
            case .notTrusted:
                return "Accessibility permission is required to type at the cursor"
            case .eventCreationFailed:
                return "could not synthesise a keyboard event"
            }
        }
    }

    /// `keyboardSetUnicodeString` is documented as unreliable past ~20 UTF-16
    /// units per event.
    private let chunkSize = 16

    public init() {}

    public func type(_ text: String) throws {
        guard AXIsProcessTrusted() else { throw InjectionError.notTrusted }
        guard !text.isEmpty else { return }

        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])

            guard let down = CGEvent(keyboardEventSource: source,
                                     virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source,
                                   virtualKey: 0, keyDown: false) else {
                throw InjectionError.eventCreationFailed
            }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
        }
    }

    /// Take back characters this app typed.
    ///
    /// F18 forbids using this to revise text *automatically*, and the
    /// reasoning holds: backspacing breaks terminals and submits half-finished
    /// messages in chat boxes that send on Enter. Nothing in the dictation
    /// path calls it.
    ///
    /// Fix-last does, and the difference is consent and immediacy. The user
    /// asked by name, seconds after the text appeared, having been shown how
    /// many characters will go. `DictationController.canReplaceLastUtterance`
    /// is the bound on that; this function is only the mechanism.
    public func deleteBackward(count: Int) throws {
        guard AXIsProcessTrusted() else { throw InjectionError.notTrusted }
        let source = CGEventSource(stateID: .combinedSessionState)
        let delete = CGKeyCode(0x33)   // kVK_Delete
        for _ in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: delete, keyDown: true)?
                .post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: delete, keyDown: false)?
                .post(tap: .cghidEventTap)
        }
    }

    /// The bundle identifier of the frontmost app, which drives profile
    /// selection at M6. Reading which app is frontmost is not reading its
    /// contents.
    public static func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
