import XCTest
@testable import CochleaASR
import CochleaCore

/// The Swift half of the D5 protocol. The Python half is covered by
/// tests/test_sidecar.py, which runs without MLX; these cover the parts that
/// only exist on this side — the wire encoding of audio, executable lookup,
/// and the errors a user has to be able to act on.
final class SidecarEncodingTests: XCTestCase {

    func testSamplesEncodeAsLittleEndianFloat32() {
        // What AudioCapture produces and what Whisper's frontend consumes, so
        // nothing resamples in between. Four bytes per sample, in order.
        let data = SidecarIO.encode(samples: [1.0, -1.0])
        XCTAssertEqual(data.count, 8)
        let round: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(round, [1.0, -1.0])
    }

    func testAnEmptyUtteranceEncodesToNothing() {
        XCTAssertTrue(SidecarIO.encode(samples: []).isEmpty)
    }

    func testByteCountAlwaysMatchesTheDeclaredSampleCount() {
        // The header declares a sample count and the reader trusts it for
        // exactly this many bytes; a mismatch desynchronises the stream.
        for count in [1, 3, 1024, 204_226] {
            let samples = [Float](repeating: 0.25, count: count)
            XCTAssertEqual(SidecarIO.encode(samples: samples).count, count * 4)
        }
    }
}

final class SidecarLocationTests: XCTestCase {

    func testAnExplicitOverrideWins() {
        let found = SidecarTranscriber.locateExecutable(
            environment: ["COCHLEA_DICTATE": "/somewhere/dictate"])
        XCTAssertEqual(found?.path, "/somewhere/dictate")
    }

    func testPathIsNeverConsulted() {
        // A GUI app launched from Finder does not inherit the shell's PATH, so
        // honouring it would work from a terminal and fail on double-click.
        XCTAssertFalse(SidecarTranscriber.searchPaths.contains { $0 == "dictate" })
        for path in SidecarTranscriber.searchPaths {
            XCTAssertTrue(path.hasPrefix("/"), "\(path) is not absolute")
        }
    }
}

final class SidecarErrorTests: XCTestCase {

    func testAMissingHelperSaysHowToInstallIt() {
        let message = SidecarError.executableNotFound("/opt/homebrew/bin/dictate").description
        XCTAssertTrue(message.contains("brew install"))
        XCTAssertTrue(message.contains("COCHLEA_DICTATE"))
    }

    func testAProtocolMismatchNamesBothVersions() {
        let message = SidecarError.protocolMismatch(expected: 1, found: 2).description
        XCTAssertTrue(message.contains("1") && message.contains("2"))
    }
}

final class UnavailableTranscriberTests: XCTestCase {

    func testItRefusesRatherThanReturningPlaceholderText() async {
        // Typing invented words at the user's cursor is worse than typing
        // nothing. This is the behaviour that guarantee rests on.
        do {
            _ = try await UnavailableTranscriber().transcribe(samples: [0.1])
            XCTFail("a transcriber with no model must not return text")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    func testTheReasonReachesTheUser() async {
        let transcriber = UnavailableTranscriber(reason: "the model is not installed")
        do {
            _ = try await transcriber.transcribe(samples: [0.1])
            XCTFail("expected a throw")
        } catch let error as TranscriberError {
            XCTAssertEqual(error.description, "the model is not installed")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}

final class TranscriberFactoryTests: XCTestCase {

    func testAMissingModelIsReportedSeparatelyFromAMissingHelper() {
        // Two different fixes, so two different messages.
        var configuration = Configuration(home: URL(fileURLWithPath: "/tmp/cochlea-absent"))
        configuration.modelIdentifier = "whisper-small"
        let transcriber = TranscriberFactory.make(configuration: configuration)
        guard let unavailable = transcriber as? UnavailableTranscriber else {
            return XCTFail("expected no transcriber with neither helper nor model")
        }
        XCTAssertFalse(unavailable.reason.isEmpty)
    }

    func testConfigurationDefaultsToACatalogueModel() {
        // The default was the literal "whisper-turbo", which matches no
        // descriptor; nothing read it, so it never fired.
        let identifier = Configuration(home: URL(fileURLWithPath: "/tmp/x")).modelIdentifier
        XCTAssertNotNil(ModelCatalog.descriptor(for: identifier))
    }
}
