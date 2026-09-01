import Foundation

/// Runs queued work strictly in the order it was queued.
///
/// Streaming turns one transcription per session into several, and they must
/// reach the cursor in the order they were spoken. Nothing else guarantees
/// that: two segments handed to `Task { }` independently race, and the second
/// wins whenever it happens to decode faster — which a shorter segment
/// routinely does. Out-of-order text is not a glitch the user can ignore,
/// because F18 forbids backspacing, so once it is typed it is what they said.
///
/// The mechanism is one link per item: each task awaits its predecessor's
/// value before doing anything. Because links are only ever created here, on
/// the main actor, in the order the audio finished, the chain is FIFO by
/// construction rather than by scheduling luck.
@MainActor
public final class CommitQueue {

    private var tail: Task<Void, Never>?

    /// How many items have been queued, for diagnostics.
    public private(set) var depth = 0

    public init() {}

    public func enqueue(_ work: @escaping @Sendable @MainActor () async -> Void) {
        let previous = tail
        depth += 1
        tail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Waits for everything queued so far.
    ///
    /// Only for what is already in the queue at the moment of the call — work
    /// added later is not waited on, which is what a caller ending a session
    /// wants.
    public func drain() async {
        await tail?.value
    }

    public func cancel() {
        tail?.cancel()
        tail = nil
    }
}
