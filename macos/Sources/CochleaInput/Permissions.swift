import ApplicationServices
import Foundation

/// Accessibility permission, requested only when the feature needs it.
///
/// Invariant 8: no permission is requested before the feature that needs it is
/// invoked. `isTrusted()` never prompts; `requestTrust()` does, and is called
/// from the first dictation attempt, not from the app delegate.
public enum AccessibilityPermission {

    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user. Returns the state immediately after the call; macOS
    /// grants asynchronously, so a false here is normal on first run.
    @discardableResult
    public static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static let explanation = """
        cochlea types transcribed text at your cursor, which macOS treats as \
        controlling your computer. That is the only thing this permission is \
        used for.

        cochlea does not read the contents of other applications. Corrections \
        are captured only when you explicitly make them, through the fix-last \
        hotkey or the review queue.
        """
}
