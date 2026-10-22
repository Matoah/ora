import XCTest
@testable import Ora

final class CaptionTextTrackTests: XCTestCase {
    func testChangedGreetingCannotReplayReadPrefixOrLoseUnreadSentence() {
        var track = CaptionTextTrack()
        track.update("你好。第二句话。", final: false)
        track.consume("你好。")
        track.update("您好。第二句话。还有新内容。", final: false)
        XCTAssertEqual(track.consumed, "你好。")
        XCTAssertEqual(track.remaining, "第二句话。还有新内容。")
        track.consume("第二句话。")
        track.update("朋友您好。第二句话。还有新内容。", final: true)
        XCTAssertEqual(track.remaining, "还有新内容。")
    }

    func testInsertionAtReadBoundaryIsStillUnread() {
        var track = CaptionTextTrack()
        track.update("第一句。", final: false)
        track.consume("第一句。")
        track.update("第一句。第二句。", final: true)
        XCTAssertEqual(track.remaining, "第二句。")
    }

    func testDeletedReadTextDoesNotConsumeUnseenWords() {
        var track = CaptionTextTrack()
        track.update("你好。下一步。", final: false)
        track.consume("你好。")
        track.update("下一步。", final: true)
        XCTAssertEqual(track.remaining, "下一步。")
    }

    func testIncompleteReplacementDoesNotErasePendingText() {
        var track = CaptionTextTrack()
        track.update("你好。下一步。", final: false)
        track.consume("你好。")
        track.update("您", final: false)
        XCTAssertEqual(track.remaining, "下一步。")
        track.update("您好。下一步。", final: true)
        XCTAssertEqual(track.remaining, "下一步。")
    }

    func testUnreadCorrectionsAndEmojiArePreserved() {
        var track = CaptionTextTrack()
        track.update("👨‍👩‍👧‍👦 你好。下一步。", final: false)
        track.consume("👨‍👩‍👧‍👦 你好。")
        track.update("👨‍👩‍👧‍👦 您好。接着做饭🇨🇦。", final: true)
        XCTAssertEqual(track.remaining, "接着做饭🇨🇦。")
    }
}
