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

    func testEveryShippedModelIsPinned() {
        // docs/DECISIONS.md D4. This was the inverse assertion until the
        // digests could be obtained: D2 shipped `pinnedSHA256` empty because
        // the build environment could not reach huggingface.co, and required
        // pinning before distribution. They have now been resolved and
        // committed, so the requirement is a test rather than a note.
        for model in ModelCatalog.known {
            XCTAssertTrue(model.isPinned, "\(model.identifier) is not pinned")
        }
    }

    func testPinnedDigestsCoverTheWeightsAndTheConfig() {
        // A partial pin is the dangerous case: ModelDownloader refuses any
        // file with no digest, so a model pinned for its weights alone cannot
        // install at all. Both files this resolver asks for must be present.
        let turbo = ModelCatalog.whisperLargeV3Turbo
        XCTAssertNotNil(turbo.pinnedSHA256["weights.safetensors"])
        XCTAssertNotNil(turbo.pinnedSHA256["config.json"])
        XCTAssertNotNil(ModelCatalog.whisperSmall.pinnedSHA256["weights.npz"])
        XCTAssertNotNil(ModelCatalog.whisperSmall.pinnedSHA256["config.json"])
    }

    func testPinnedDigestsAreSHA256AndNotGitObjectIDs() {
        // A git blob oid is a 40-character SHA-1. Committing one would fail
        // every download as a checksum mismatch that reads like corruption.
        for model in ModelCatalog.known {
            for (file, digest) in model.pinnedSHA256 {
                XCTAssertTrue(ModelResolver.isSHA256(digest),
                              "\(model.identifier)/\(file) is not a SHA-256")
                XCTAssertEqual(digest, digest.lowercased(),
                               "\(model.identifier)/\(file) must be lowercase")
            }
        }
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

    // MARK: - Digest parsing (D4)
    //
    // These are the shapes huggingface.co actually returns, recorded from
    // mlx-community/whisper-large-v3-turbo. The resolver read `lfs.oid` from
    // the `?blobs=true` endpoint, which spells the digest `lfs.sha256` — so
    // every file resolved to a nil digest, ModelDownloader refused all of
    // them as unverifiable, and first-run download could never succeed.

    func testDigestIsReadFromTheBlobsEndpointSpelling() {
        let entry: [String: Any] = [
            "rfilename": "weights.safetensors",
            "size": 1_613_977_612,
            "lfs": ["sha256": "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6",
                    "size": 1_613_977_612],
        ]
        XCTAssertEqual(ModelResolver.providerDigest(from: entry),
                       "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6")
    }

    func testDigestIsReadFromThePathsInfoSpelling() {
        // The same value under the other endpoint's key.
        let entry: [String: Any] = [
            "lfs": ["oid": "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"],
        ]
        XCTAssertEqual(ModelResolver.providerDigest(from: entry),
                       "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6")
    }

    func testTopLevelGitObjectIDIsNeverMistakenForADigest() {
        // config.json is not LFS-tracked, so the provider offers only the git
        // blob SHA-1. Forty characters, and not a hash of the contents.
        let entry: [String: Any] = [
            "rfilename": "config.json",
            "blobId": "6ac9a52a28f70a2e5681c250a470eca6e9c8cc3e",
            "oid": "6ac9a52a28f70a2e5681c250a470eca6e9c8cc3e",
            "size": 268,
        ]
        XCTAssertNil(ModelResolver.providerDigest(from: entry))
    }

    func testDigestIsNormalisedToLowercase() {
        // ModelDownloader formats its computed digest with %02x, so an
        // uppercase expectation would mismatch a byte-identical file.
        let entry: [String: Any] = [
            "lfs": ["sha256": "951ED3FC1203E6A62467ABB2144A96CE7EAFCA8FA77E3704FDB8635FF3E7F8A6"],
        ]
        XCTAssertEqual(ModelResolver.providerDigest(from: entry),
                       "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6")
    }

    func testSHA256WidthCheckRejectsSHA1() {
        XCTAssertTrue(ModelResolver.isSHA256(
            "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"))
        XCTAssertFalse(ModelResolver.isSHA256(
            "6ac9a52a28f70a2e5681c250a470eca6e9c8cc3e"))
        XCTAssertFalse(ModelResolver.isSHA256(""))
        XCTAssertFalse(ModelResolver.isSHA256(
            "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
    }
}
