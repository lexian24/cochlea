import XCTest
@testable import CochleaCore

/// Tests for the parts of M0 that are testable without a microphone, a model,
/// or Accessibility permission. They have NOT been executed — see macos/README.md.
final class ConfigurationTests: XCTestCase {

    func testAcousticRetentionDefaultsOff() {
        // SPEC invariant 7.
        XCTAssertFalse(Configuration(home: URL(fileURLWithPath: "/tmp/x"))
            .acousticRetentionEnabled)
    }

    func testPostCorrectionIsDisabledInLiveStreaming() {
        // SPEC F18.
        XCTAssertTrue(Configuration.Mode.commitOnRelease.allowsPostCorrection)
        XCTAssertFalse(Configuration.Mode.liveStreaming.allowsPostCorrection)
    }

    func testHomeHonoursEnvironmentOverride() throws {
        let config = Configuration(home: URL(fileURLWithPath: "/tmp/cochlea-test"))
        XCTAssertEqual(config.modelsDirectory.lastPathComponent, "models")
    }

    func testRoundTripsThroughJSON() throws {
        var config = Configuration(home: URL(fileURLWithPath: "/tmp/cochlea-test"))
        config.mode = .liveStreaming
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(decoded.mode, .liveStreaming)
    }
}

final class LatencyRecorderTests: XCTestCase {

    func testColdAndWarmAreReportedSeparately() {
        // F19 assigned to M0: one number cannot cover both.
        let recorder = LatencyRecorder()
        recorder.record(LatencySample(captureMillis: 100, inferenceMillis: 2900,
                                      injectionMillis: 0, wasColdStart: true))
        for _ in 0..<3 {
            recorder.record(LatencySample(captureMillis: 100, inferenceMillis: 300,
                                          injectionMillis: 20, wasColdStart: false))
        }
        XCTAssertEqual(recorder.coldMedianMillis, 3000)
        XCTAssertEqual(recorder.warmMedianMillis, 420)
        XCTAssertTrue(recorder.meetsBudget(1000))
    }

    func testBudgetIsNotMetWithNoWarmSamples() {
        XCTAssertFalse(LatencyRecorder().meetsBudget(1000))
    }
}

final class ModelCatalogTests: XCTestCase {

    func testCatalogIsEmptyUntilTheBenchmarkAndLicenceAuditAreDone() {
        // SPEC §7 leaves the default model open; F23 requires a licence audit
        // before distribution. Shipping a URL here would invent both answers.
        XCTAssertTrue(ModelCatalog.known.isEmpty)
        XCTAssertNil(ModelCatalog.descriptor(for: "whisper-turbo"))
    }
}
