import AVFoundation
import XCTest
@testable import CochleaAudio

/// The device-change path, tested without a microphone.
///
/// T6 in macos/TESTING.md: connecting AirPods mid-session stopped dictation
/// dead. `AVAudioEngine` binds to the input device it was built against, and
/// nothing observed `AVAudioEngineConfigurationChange`, so the engine kept a
/// reference to hardware that no longer existed and `start()` blocked forever
/// — on the main actor, taking the whole app with it. Three hotkey presses
/// produced no log line at all.
///
/// CI runners have no microphone, so these cover the wiring rather than the
/// audio: that the notification is observed and that it marks the graph for
/// rebuild. Whether the rebuilt graph then captures needs real hardware and a
/// person, which is what T6 is for.
final class AudioCaptureDeviceChangeTests: XCTestCase {

    func testAConfigurationChangeMarksTheGraphForRebuild() {
        let capture = AudioCapture()
        XCTAssertFalse(capture.hasPendingRebuild)

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: nil)

        // The observer runs on the posting thread for a nil queue.
        XCTAssertTrue(capture.hasPendingRebuild,
                      "a device change must not leave the old graph in place")
    }

    func testTheFlagSurvivesUntilSomethingActsOnIt() {
        // Set while idle, consumed on the next press — the change usually
        // happens between utterances, not during one.
        let capture = AudioCapture()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertTrue(capture.hasPendingRebuild)
        XCTAssertTrue(capture.hasPendingRebuild, "reading it must not clear it")
    }

    func testStoppingIsSafeWithAPendingRebuild() {
        // stop() is how the microphone gets closed, so it is the one path that
        // must work even when the device it was opened on is gone. Touching
        // the stale input node is what hangs.
        let capture = AudioCapture()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: nil)
        capture.stop()          // must not hang or trap
    }

    func testPrewarmIsSkippedWithoutPermission() {
        // Invariant 8: reporting a permission is not requesting one, and a
        // runner with no microphone must not be prompted or blocked.
        if !AudioCapture.hasPermission {
            XCTAssertFalse(AudioCapture().prewarm())
        }
    }
}
