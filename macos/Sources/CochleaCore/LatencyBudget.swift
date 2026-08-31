import Foundation

/// Measures the end-to-end latency M0 is accepted against, split into the
/// phases that can actually regress independently.
///
/// F19's assignment to M0 means the cold first invocation is bounded
/// separately from the warm median: one number cannot cover both, and
/// reporting only the warm median hides exactly the failure F19 describes.
public struct LatencySample: Sendable {
    public let captureMillis: Int
    public let inferenceMillis: Int
    public let injectionMillis: Int
    public let wasColdStart: Bool

    public var totalMillis: Int { captureMillis + inferenceMillis + injectionMillis }

    public init(captureMillis: Int, inferenceMillis: Int,
                injectionMillis: Int, wasColdStart: Bool) {
        self.captureMillis = captureMillis
        self.inferenceMillis = inferenceMillis
        self.injectionMillis = injectionMillis
        self.wasColdStart = wasColdStart
    }
}

public final class LatencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var warm: [Int] = []
    private var cold: [Int] = []

    public init() {}

    public func record(_ sample: LatencySample) {
        lock.lock(); defer { lock.unlock() }
        if sample.wasColdStart { cold.append(sample.totalMillis) }
        else { warm.append(sample.totalMillis) }
    }

    // The arrays are read under the lock and the median computed on a copy.
    // Reading `warm` in the computed property and locking inside the helper
    // would leave the read itself unsynchronised.
    public var warmMedianMillis: Int? {
        lock.lock(); defer { lock.unlock() }
        return Self.median(of: warm)
    }

    public var coldMedianMillis: Int? {
        lock.lock(); defer { lock.unlock() }
        return Self.median(of: cold)
    }

    /// M0's acceptance: warm median under the budget.
    public func meetsBudget(_ budgetMillis: Int) -> Bool {
        guard let warmMedian = warmMedianMillis else { return false }
        return warmMedian <= budgetMillis
    }

    private static func median(of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
