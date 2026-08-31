import Foundation
import os

/// A running account of what the app did, for the things a compiler and a unit
/// test cannot check.
///
/// M0's remaining unknowns are all runtime and all silent when they fail: a
/// hotkey that reports key-down but not key-up leaves the app listening
/// forever, an `AVAudioConverter` built for the wrong device returns nothing,
/// and a chunked `keyboardSetUnicodeString` drops characters without an error.
/// None of those raise. Without a log, testing them is guesswork about which
/// of four silent failures happened.
///
/// Writes to both the unified log and stderr, because the app is launched two
/// ways during testing and each way sees only one of them:
///
/// - from a terminal, stderr is right there;
/// - from Finder there is no stderr, and
///   `log stream --predicate 'subsystem == "com.cochlea.app"'` is.
public enum Diagnostics {

    public static let subsystem = "com.cochlea.app"

    /// On by default. This costs a few microseconds per event against events
    /// that happen at human speed, and an M0 whose runtime behaviour is
    /// unverified is exactly the wrong place to make the log opt-in — the
    /// person who needs it is the one who did not know they would.
    /// `COCHLEA_QUIET=1` turns it off.
    public static let isEnabled =
        ProcessInfo.processInfo.environment["COCHLEA_QUIET"] != "1"

    private static let logger = Logger(subsystem: subsystem, category: "dictation")
    private static let started = Date()

    public static func log(_ category: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.log("[\(category, privacy: .public)] \(text, privacy: .public)")
        let stamp = String(format: "%7.3f", Date().timeIntervalSince(started))
        FileHandle.standardError.write(
            Data("\(stamp) [\(category)] \(text)\n".utf8))
    }

    /// The state a tester needs before pressing anything: which model, which
    /// helper, whether the permissions are already granted.
    public static func banner(_ lines: [String]) {
        guard isEnabled else { return }
        log("start", "cochlea diagnostics — COCHLEA_QUIET=1 to silence")
        for line in lines { log("start", line) }
    }
}
