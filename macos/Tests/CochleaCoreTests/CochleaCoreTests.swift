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

    func testDefaultIsWhisperLargeV3Turbo() {
        // docs/DECISIONS.md D1.
        XCTAssertEqual(ModelCatalog.default.identifier, "whisper-large-v3-turbo")
    }

    func testDefaultCarriesLargeV3MelBinCount() {
        // §1.2: stored mel features are bound to the model that produced them,
        // so the bin count is part of the model's identity. large-v3 and its
        // turbo derivative use 128, not the 80 of earlier variants.
        XCTAssertEqual(ModelCatalog.default.melBins, 128)
        XCTAssertEqual(ModelCatalog.whisperSmall.melBins, 80)
    }

    func testEveryShippedModelRecordsALicence() {
        // F23.
        for model in ModelCatalog.known {
            XCTAssertFalse(model.license.isEmpty, "\(model.identifier) has no licence")
        }
    }

    func testNothingIsPinnedYetAndThatIsDeliberate() {
        // docs/DECISIONS.md D2: this build could not reach the provider, and a
        // fabricated digest would fail every download as a checksum mismatch
        // that reads like corruption. Pinning is required before distribution.
        XCTAssertFalse(ModelCatalog.default.isPinned)
    }

    func testDescriptorLookup() {
        XCTAssertNotNil(ModelCatalog.descriptor(for: "whisper-large-v3-turbo"))
        XCTAssertNil(ModelCatalog.descriptor(for: "sensevoice-small"))
    }
}

final class ModelResolverTests: XCTestCase {

    func testWeightFilesAreRecognised() {
        XCTAssertTrue(ModelResolver.isWeights("weights.safetensors"))
        XCTAssertTrue(ModelResolver.isWeights("weights.npz"))
        XCTAssertFalse(ModelResolver.isWeights("config.json"))
    }

    func testNeededFilesExcludeNestedVariants() {
        // A repo often carries several quantisations in subdirectories;
        // pulling all of them would download many gigabytes.
        XCTAssertTrue(ModelResolver.isNeeded("config.json"))
        XCTAssertTrue(ModelResolver.isNeeded("weights.safetensors"))
        XCTAssertFalse(ModelResolver.isNeeded("4bit/weights.safetensors"))
        XCTAssertFalse(ModelResolver.isNeeded("README.md"))
    }
}
