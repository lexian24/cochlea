import XCTest
@testable import CochleaCore

/// The ordering guarantee, tested where it can fail: with work that finishes
/// in the opposite order to the order it was queued.
@MainActor
final class CommitQueueTests: XCTestCase {

    func testWorkRunsInTheOrderItWasQueued() async {
        // Each item sleeps for less time than the one before, so anything that
        // does not serialise finishes them backwards. Without the queue this
        // reliably produced 4, 3, 2, 1, 0 -- and out-of-order text cannot be
        // taken back, because F18 forbids backspacing.
        let queue = CommitQueue()
        let recorder = Recorder()
        for index in 0..<5 {
            let delay = UInt64((5 - index) * 20) * 1_000_000
            queue.enqueue {
                try? await Task.sleep(nanoseconds: delay)
                await recorder.append(index)
            }
        }
        await queue.drain()
        let order = await recorder.values
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
    }

    func testDrainWaitsForEverythingQueuedSoFar() async {
        // `endListening` relies on this: the session is not over until its
        // last segment is at the cursor, or the menu bar says "ready" while
        // text is still arriving.
        let queue = CommitQueue()
        let recorder = Recorder()
        queue.enqueue {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await recorder.append(1)
        }
        await queue.drain()
        let count = await recorder.values.count
        XCTAssertEqual(count, 1)
    }

    func testAnEmptyQueueDrainsImmediately() async {
        await CommitQueue().drain()
    }

    func testDepthCountsWhatWasQueued() {
        let queue = CommitQueue()
        XCTAssertEqual(queue.depth, 0)
        queue.enqueue {}
        queue.enqueue {}
        XCTAssertEqual(queue.depth, 2)
    }
}

private actor Recorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
