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

    /// F18: live streaming mode cannot revise already-typed text.
    ///
    /// Backspacing to correct would break terminals and send-on-enter chat
    /// boxes, so this exists to be *called only* in commit-on-release mode,
    /// where nothing has been typed yet.
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
