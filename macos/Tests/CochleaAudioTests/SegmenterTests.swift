import XCTest
@testable import CochleaAudio

/// The numbers here are measured, not invented.
///
/// A MacBook Air in an ordinary room idles at 0.0166–0.0386 RMS. The detector
/// compared against a fixed 0.012, so every frame of silence counted as
/// speech: a four-second pause did not end an utterance, and the
/// accidental-tap guard never rejected anything, because both read the same
/// signal. A threshold a microphone's own noise clears is not a threshold.
private let measuredQuietRoom: [Float] = [0.0166, 0.0288, 0.0344, 0.0386, 0.0230]

/// A constant-magnitude frame has exactly this RMS. 1600 samples is 0.1 s.
private func frame(_ rms: Float) -> [Float] { [Float](repeating: rms, count: 1600) }

/// Room tone before speech, which is what really happens: the microphone opens
/// on key-down and nobody starts talking in the same instant.
private func feedRoomTone(_ segmenter: Segmenter, frames: Int = 3) {
    for i in 0..<frames { _ = segmenter.accept(frame: frame(measuredQuietRoom[i % 5])) }
}

final class NoiseFloorTests: XCTestCase {

    func testItFallsImmediately() {
        // The estimate is seeded from the first frame, which is whatever the
        // user happened to be doing. If that was loud, one quiet frame must
        // correct it.
        var floor = NoiseFloor()
        floor.observe(0.5, wasSpeech: true)
        floor.observe(0.02, wasSpeech: false)
        XCTAssertEqual(floor.level!, 0.02, accuracy: 1e-6)
    }

    func testSpeechDoesNotDragTheFloorUp() {
        // A sustained loud passage must not raise the floor behind it, or the
        // detector stops hearing the speech it is measuring.
        var floor = NoiseFloor()
        floor.observe(0.02, wasSpeech: false)
        for _ in 0..<500 { floor.observe(0.4, wasSpeech: true) }
        XCTAssertEqual(floor.level!, 0.02, accuracy: 1e-6)
    }

    func testItDriftsUpOnNonSpeech() {
        // A fan switching on is not speech, and the floor should follow it.
        var floor = NoiseFloor()
        floor.observe(0.01, wasSpeech: false)
        for _ in 0..<200 { floor.observe(0.05, wasSpeech: false) }
        XCTAssertEqual(floor.level!, 0.05, accuracy: 0.001)
    }
}

final class SegmenterTests: XCTestCase {

    // MARK: - the regression

    func testARealRoomsSilenceNeverBecomesAnUtterance() {
        let segmenter = Segmenter()
        for i in 0..<60 { _ = segmenter.accept(frame: frame(measuredQuietRoom[i % 5])) }
        XCTAssertNil(segmenter.finish(),
                     "room tone alone was transcribed as if it were speech")
    }

    func testTheThresholdLandsBetweenTheRoomAndOrdinarySpeech() {
        let segmenter = Segmenter()
        for i in 0..<20 { _ = segmenter.accept(frame: frame(measuredQuietRoom[i % 5])) }
        XCTAssertGreaterThan(segmenter.currentThreshold, 0.0386,   // the room's peak
                             "silence would still count as speech")
        XCTAssertLessThan(segmenter.currentThreshold, 0.1,         // ordinary speech
                          "speech would not count as speech")
    }

    // MARK: - segmentation

    func testSpeechThenSilenceEndsOnTheHangover() {
        let segmenter = Segmenter()
        feedRoomTone(segmenter)
        for _ in 0..<15 { _ = segmenter.accept(frame: frame(0.25)) }

        var finished: [Float]?
        var silentFrames = 0
        for i in 0..<40 where finished == nil {
            finished = segmenter.accept(frame: frame(measuredQuietRoom[i % 5]))
            silentFrames += 1
        }
        XCTAssertNotNil(finished, "speech followed by silence must end")
        // 1.5 s of hangover at 0.1 s a frame, give or take the frame it ends on.
        XCTAssertGreaterThanOrEqual(silentFrames, 15)
        XCTAssertLessThanOrEqual(silentFrames, 17)
    }

    func testAShortPauseDoesNotEndAnUtterance() {
        // People pause mid-sentence to think. The hangover was 0.6 s, which is
        // shorter than that pause; it is 1.5 s now.
        let segmenter = Segmenter()
        feedRoomTone(segmenter)
        for _ in 0..<10 { _ = segmenter.accept(frame: frame(0.25)) }
        for i in 0..<8 {   // 0.8 s
            XCTAssertNil(segmenter.accept(frame: frame(measuredQuietRoom[i % 5])),
                         "a 0.8 s pause must not end the utterance")
        }
    }

    // MARK: - the ceiling

    func testSpeakingImmediatelyIsNotDiscarded() {
        // Without a ceiling on the threshold this failed, and failed worse
        // than the bug it fixes: the floor seeds from the first frame, so
        // speaking at once seeds it with speech, the threshold went to 0.75,
        // every frame read as silence and the utterance was thrown away.
        let segmenter = Segmenter()
        for _ in 0..<10 { _ = segmenter.accept(frame: frame(0.25)) }
        XCTAssertNotNil(segmenter.finish(),
                        "an utterance was discarded because it started at once")
    }

    func testANoisierRoomDemandsALouderFrame() {
        let quiet = Segmenter()
        for _ in 0..<20 { _ = quiet.accept(frame: frame(0.002)) }
        let loud = Segmenter()
        for _ in 0..<20 { _ = loud.accept(frame: frame(0.03)) }
        XCTAssertGreaterThan(loud.currentThreshold, quiet.currentThreshold)
    }

    func testTheThresholdNeverFallsBelowTheAbsoluteFloor() {
        // A silent room must not drive the threshold to zero and start
        // transcribing the microphone's own hiss.
        let segmenter = Segmenter()
        for _ in 0..<50 { _ = segmenter.accept(frame: frame(0.0)) }
        XCTAssertGreaterThanOrEqual(segmenter.currentThreshold,
                                    VoiceActivityDetector.Parameters().floorThreshold)
    }

    // MARK: - the tap guard, which reads the same signal

    func testAnAccidentalTapIsDiscarded() {
        let segmenter = Segmenter()
        for i in 0..<2 { _ = segmenter.accept(frame: frame(measuredQuietRoom[i % 5])) }
        XCTAssertNil(segmenter.finish())
    }

    func testAGenuineUtteranceSurvivesFinish() {
        let segmenter = Segmenter()
        feedRoomTone(segmenter)
        for _ in 0..<10 { _ = segmenter.accept(frame: frame(0.3)) }
        XCTAssertNotNil(segmenter.finish())
    }

    // MARK: - what the log is allowed to claim

    func testTheDecisionIsRecordedBeforeResetClearsIt() {
        // `finish()` resets the estimate, so anything read after it reports a
        // cleared floor of 0.0000 and the absolute-minimum threshold. The log
        // printed exactly that during hand-testing, which is a false statement
        // about a detector that had in fact worked correctly.
        let segmenter = Segmenter()
        feedRoomTone(segmenter)
        for _ in 0..<18 { _ = segmenter.accept(frame: frame(0.25)) }
        var finished: [Float]?
        for i in 0..<40 where finished == nil {
            finished = segmenter.accept(frame: frame(measuredQuietRoom[i % 5]))
        }
        XCTAssertNotNil(finished)
        XCTAssertNil(segmenter.currentNoiseFloor, "reset should have cleared it")
        XCTAssertGreaterThan(segmenter.decisionNoiseFloor ?? 0, 0.01,
                             "the decision floor must survive the reset")
        XCTAssertGreaterThan(segmenter.decisionThreshold, 0.0386)
        XCTAssertGreaterThan(segmenter.decisionSpeechSeconds, 1.0)
    }

    func testSilenceAndABriefTapAreDistinguishable() {
        // Holding the key through silence after an utterance already finished
        // is the normal end of a dictation, not a mistake, and calling both
        // "an accidental tap" told the user the wrong thing.
        let silent = Segmenter()
        for i in 0..<60 { _ = silent.accept(frame: frame(measuredQuietRoom[i % 5])) }
        _ = silent.finish()
        XCTAssertEqual(silent.decisionSpeechSeconds, 0,
                       "room tone must not be charged as speech")

        let tapped = Segmenter()
        feedRoomTone(tapped)
        _ = tapped.accept(frame: frame(0.3))        // 0.1 s, under the 0.25 s minimum
        _ = tapped.finish()
        XCTAssertGreaterThan(tapped.decisionSpeechSeconds, 0)
        XCTAssertLessThan(tapped.decisionSpeechSeconds, 0.25)
    }

    func testTheFirstFrameIsNotAutomaticallySpeech() {
        // With no estimate the threshold falls back to the absolute floor,
        // which ordinary room tone clears -- so the first frame of every
        // utterance counted as speech, charging 0.1 s of phantom speech
        // against the accidental-tap guard.
        let segmenter = Segmenter()
        _ = segmenter.accept(frame: frame(measuredQuietRoom[0]))
        _ = segmenter.finish()
        XCTAssertEqual(segmenter.decisionSpeechSeconds, 0)
    }

    func testResetRemeasuresTheRoom() {
        // The user may have moved, put headphones on, or closed a window.
        let segmenter = Segmenter()
        for _ in 0..<10 { _ = segmenter.accept(frame: frame(0.3)) }
        segmenter.reset()
        XCTAssertNil(segmenter.currentNoiseFloor)
    }
}
