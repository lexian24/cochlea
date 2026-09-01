import XCTest
@testable import CochleaCore

/// Streaming makes the separator between segments a decision the app has to
/// make on every sentence, so these are the cases it gets wrong when it does
/// the obvious thing.
final class TranscriptJoinerTests: XCTestCase {

    func testTheFirstSegmentGetsNoLeadingSpace() {
        // A session starts wherever the cursor is, which may be the start of a
        // line, a bullet, or an empty file.
        var joiner = TranscriptJoiner()
        XCTAssertEqual(joiner.join("hello"), "hello")
    }

    func testConsecutiveSegmentsAreSpaced() {
        var joiner = TranscriptJoiner()
        _ = joiner.join("hello there")
        XCTAssertEqual(joiner.join("how are you"), " how are you")
    }

    func testWhisperWhitespaceIsNormalisedRatherThanInherited() {
        // mlx-whisper returns segments with a leading space more often than
        // not, but not always. Trusting it gives a double space in one
        // sentence and none in the next.
        var joiner = TranscriptJoiner()
        _ = joiner.join(" hello there ")
        XCTAssertEqual(joiner.join(" how are you"), " how are you")
    }

    func testASegmentThatIsOnlyWhitespaceCommitsNothing() {
        // A pause the model transcribes as "" or " " must not consume the
        // separator decision, or the next real segment loses its space.
        var joiner = TranscriptJoiner()
        _ = joiner.join("hello")
        XCTAssertNil(joiner.join("   "))
        XCTAssertEqual(joiner.join("world"), " world")
    }

    func testPunctuationAttachesToTheWordBeforeIt() {
        // Whisper splits at pauses, and a pause lands before a comma often
        // enough to matter. " ," in every other sentence is worse than the
        // occasional missing space.
        var joiner = TranscriptJoiner()
        _ = joiner.join("hello")
        XCTAssertEqual(joiner.join(", how are you"), ", how are you")
    }

    func testChineseSegmentsAreNotSpaced() {
        // P1 dictates in both. Chinese is not written with spaces between
        // words, so the rule that fixes English breaks it.
        var joiner = TranscriptJoiner()
        _ = joiner.join("你好")
        XCTAssertEqual(joiner.join("世界"), "世界")
    }

    func testACodeSwitchBoundaryFollowsTheUnspacedSide() {
        // Mixed input is the point of P1. Neither side's rule can win
        // unconditionally, so the script that does not space wins the
        // boundary: "开会 discuss" reads correctly, "开会discuss" does not,
        // and "deploy 到" is fine either way.
        var joiner = TranscriptJoiner()
        _ = joiner.join("deploy")
        XCTAssertEqual(joiner.join("到测试环境"), "到测试环境")
    }

    func testKoreanIsSpacedDespiteBeingNearby() {
        // Hangul sits beside the CJK blocks and is easy to sweep in with
        // them, but Korean does space its words.
        var joiner = TranscriptJoiner()
        _ = joiner.join("안녕하세요")
        XCTAssertEqual(joiner.join("반갑습니다"), " 반갑습니다")
    }

    func testFullwidthPunctuationDoesNotGainASpace() {
        var joiner = TranscriptJoiner()
        _ = joiner.join("我明天开会")
        XCTAssertEqual(joiner.join("。"), "。")
    }

    func testResetForgetsThePreviousSegment() {
        // A new session types at a new cursor. Carrying the old tail across
        // puts a space at the start of a fresh line.
        var joiner = TranscriptJoiner()
        _ = joiner.join("hello")
        joiner.reset()
        XCTAssertEqual(joiner.join("world"), "world")
    }
}
