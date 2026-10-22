import AppKit
import CoreText
import XCTest
@testable import Ora

final class CaptionSchedulerTests: XCTestCase {
    func testEnglishRemainsVisibleAcrossExtraTranslationPages() {
        var scheduler = CaptionScheduler()
        let source = "Classify material properties and geometry."
        let translation = "先检查物体。对材质属性和几何形状进行分类。最后确认分类结果。"
        scheduler.update(id: UUID(), source: source, translation: translation, final: true, now: 0)
        var now = 0.0
        let cues = drain(&scheduler, now: &now)
        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertTrue(cues.allSatisfy { !$0.source.display.isEmpty }, "English must remain visible while its translation continues")
        XCTAssertEqual(cues.map(\.source.raw).joined(), source, "holding context must not consume English twice")
        XCTAssertEqual(cues.map(\.translation.raw).joined(), translation)
    }

    func testTranslationRemainsVisibleWhileLongSourceFinishes() {
        var scheduler = CaptionScheduler()
        scheduler.update(id: UUID(), source: "First sentence. Second sentence. Third sentence.", translation: "精简译文。", final: true, now: 0)
        var now = 0.0
        let cues = drain(&scheduler, now: &now)
        XCTAssertTrue(cues.allSatisfy { !$0.translation.display.isEmpty }, "must not flash blank or Translating after translation completed")
        XCTAssertEqual(cues.map(\.translation.raw).joined(), "精简译文。")
    }

    func testHeldSourceCannotLeakIntoTheNextUtterance() {
        var scheduler = CaptionScheduler()
        scheduler.update(id: UUID(), source: "Previous speaker.", translation: "上一句。还有译文。", final: true, now: 0)
        var now = 0.0
        _ = drain(&scheduler, now: &now)
        scheduler.update(id: UUID(), source: "", translation: "新的一句。", final: true, now: now)
        XCTAssertTrue(scheduler.current?.source.display.isEmpty == true)
    }

    func testOneQueuedSegmentShortensDisplayWaitImmediately() {
        var scheduler = CaptionScheduler()
        scheduler.update(id: UUID(), source: "A long sentence.", translation: "这是一句阅读时间足够长但不能挡住后面新字幕的中文翻译。", final: true, now: 0)
        scheduler.update(id: UUID(), source: "Next.", translation: "下一句。", final: true, now: 0.1)
        XCTAssertLessThanOrEqual(scheduler.nextDeadline!, 1.2, "even one queued segment must shorten the display wait")
    }

    func testLiveTranslationIsNotHeldForLongSourceReadingTime() {
        var scheduler = CaptionScheduler()
        let first = UUID(), next = UUID()
        scheduler.update(id: first,
                         source: "During this meeting we will carefully review every detail of the proposed project budget and schedule.",
                         translation: "好的。", final: true, now: 0)
        scheduler.update(id: next, source: "Next.", translation: "下一句。", final: true, now: 0.1)
        let deadline = scheduler.nextDeadline!
        print("[caption-pacing] first cue deadline=\(deadline)s")
        XCTAssertLessThanOrEqual(deadline, 2.4, "a short translation must not wait for a long source paragraph")
        var now = 0.1
        for _ in 0..<10 where scheduler.current?.utteranceID == first {
            now = scheduler.nextDeadline! + 0.01
            scheduler.advance(now: now)
        }
        XCTAssertEqual(scheduler.current?.utteranceID, next)
        print("[caption-pacing] next utterance visible at=\(now)s")
        XCTAssertLessThan(now, 2.5, "source-only trailing pages must not accumulate seconds of artificial lag")
    }

    func testRepeatedRevisionsCannotIndefinitelyPostponeUnreadPages() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "", translation: "原来的说法。", final: false, now: 0)
        scheduler.update(id: UUID(), source: "", translation: "后面的句子。", final: true, now: 0.1)
        for n in 1...5 {
            scheduler.update(id: id, source: "", translation: "第\(n)版修正说法。", final: false, now: Double(n) * 0.4)
            if let deadline = scheduler.nextDeadline {
                XCTAssertLessThanOrEqual(deadline, 2.4)
            } else {
                XCTAssertNil(scheduler.current, "a fully read live cue may await finalization, never restart its reading clock")
            }
        }
    }

    func testModelWaitIsNotChargedToFirstTranslatedCueReadingTime() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "Hello. Next sentence.", translation: nil, final: false, now: 0)
        scheduler.update(id: id, source: "Hello. Next sentence.", translation: "你好。下一句。", final: true, now: 5)
        XCTAssertEqual(scheduler.current?.translation.raw, "你好。")
        XCTAssertGreaterThanOrEqual(scheduler.nextDeadline!, 5.75)
    }
    private func pages(_ text: String, size: CGFloat = 22, width: CGFloat = 560) -> [CaptionSlice] {
        let font = CaptionTypography(translationSize: size).translationFont
        var remaining = text
        var result: [CaptionSlice] = []
        while !remaining.isEmpty, result.count < 1000 {
            let page = CaptionPaginator.page(remaining, font: font, width: width, final: true)
            XCTAssertFalse(page.raw.isEmpty)
            XCTAssertLessThanOrEqual(page.display.components(separatedBy: "\n").count, 2,
                                     "size=\(size) width=\(width) raw=\(page.raw.debugDescription) display=\(page.display.debugDescription)")
            for line in page.display.components(separatedBy: "\n") {
                let attributed = NSAttributedString(string: line, attributes: [.font: font])
                let measured = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
                XCTAssertLessThanOrEqual(measured, Double(width), line)
            }
            result.append(page)
            remaining = String(remaining.dropFirst(page.raw.count))
        }
        XCTAssertEqual(result.map(\.raw).joined(), text, "every original character must survive pagination")
        XCTAssertEqual(result.map(\.display).joined().filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace },
                       "the rendered pages, not just hidden buffers, must contain every word")
        return result
    }

    private func drain(_ scheduler: inout CaptionScheduler, now: inout TimeInterval) -> [ScheduledCaption] {
        var result: [ScheduledCaption] = []
        while let cue = scheduler.current, result.count < 1000 {
            result.append(cue)
            guard let deadline = scheduler.nextDeadline else {
                XCTFail("finalized captions must drain without new audio")
                break
            }
            now = max(now, deadline) + 0.01
            scheduler.advance(now: now)
        }
        XCTAssertFalse(scheduler.isDraining)
        return result
    }

    func testSentenceAndClauseBoundaries() {
        let text = "欢迎参加会议。今天我们讨论预算，接下来确认项目安排。"
        let result = pages(text)
        XCTAssertEqual(result.first?.raw, "欢迎参加会议。")
        XCTAssertEqual(result.last?.raw, "今天我们讨论预算，接下来确认项目安排。")
    }

    func testLongCJKLatinAndEmojiNeverDisappearAtAnySupportedSize() {
        let samples = [
            String(repeating: "连续讲话也应该全部显示而不能隐藏文字", count: 12),
            String(repeating: "Every word in this long meeting needs enough time to be read ", count: 12),
            String(repeating: "👨‍👩‍👧‍👦 开会讨论 🇨🇦 cafe\u{301} 和预算 👩🏽‍💻 ", count: 16),
            "https://example.com/" + String(repeating: "averylongunbrokentoken", count: 20)
        ]
        for size: CGFloat in [14, 22, 40] {
            for width: CGFloat in [392, 560] {
                for text in samples { _ = pages(text, size: size, width: width) }
            }
        }
    }

    func testDecimalsAndAbbreviationsAreNotSentenceEnds() {
        let text = "Dr. Chen reviewed version 3.14 and approved it. Next comes testing."
        let result = pages(text, width: 1000)
        XCTAssertEqual(result.first?.raw, "Dr. Chen reviewed version 3.14 and approved it. ")
    }

    func testQuoteStaysWithItsSentence() {
        XCTAssertEqual(pages("他说：“今天开始。”然后讨论预算。").first?.raw, "他说：“今天开始。”")
    }

    func testFIFOAndLosslessBilingualReading() {
        var scheduler = CaptionScheduler()
        var now = 0.0
        let a = UUID(), b = UUID()
        let sourceA = "Welcome to the meeting. Today we review the budget, then discuss the next steps."
        let targetA = "欢迎参加会议。今天我们审查预算，然后讨论下一步的项目安排。"
        let sourceB = String(repeating: "Please keep every word visible even when a speaker does not pause ", count: 6)
        let targetB = String(repeating: "即使讲话的人一直不停顿也要把每一个字完整显示出来", count: 6)
        scheduler.update(id: a, source: sourceA, translation: targetA, final: true, now: now)
        scheduler.update(id: b, source: sourceB, translation: targetB, final: true, now: now)
        let cues = drain(&scheduler, now: &now)
        for (id, source, translation) in [(a, sourceA, targetA), (b, sourceB, targetB)] {
            let group = cues.filter { $0.utteranceID == id }
            XCTAssertEqual(group.map(\.source.raw).joined(), source)
            XCTAssertEqual(group.map(\.translation.raw).joined(), translation)
        }
        let ids = cues.map(\.utteranceID)
        XCTAssertFalse(ids.drop(while: { $0 == a }).contains(a), "later input must not overtake unread cues")
        XCTAssertEqual(scheduler.visible, cues.last)
    }

    func testNewResultCannotOverwriteCurrentReadingBeforeDeadline() {
        var scheduler = CaptionScheduler()
        let a = UUID()
        scheduler.update(id: a, source: "First sentence.", translation: "第一句话。", final: true, now: 0)
        let first = scheduler.current
        scheduler.update(id: UUID(), source: "Second sentence.", translation: "第二句话。", final: true, now: 0.1)
        XCTAssertEqual(scheduler.current, first)
        XCTAssertEqual(scheduler.queuedUtteranceCount, 1)
        scheduler.advance(now: 0.3)
        XCTAssertEqual(scheduler.current, first)
        scheduler.advance(now: scheduler.nextDeadline! + 0.01)
        XCTAssertNotEqual(scheduler.current?.utteranceID, a)
    }

    func testStreamedPrefixDoesNotReplayWhenFinalArrives() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        var now = 0.0
        scheduler.update(id: id, source: "Hello. Next step.", translation: "你好。下一步。", final: false, now: now)
        let read = scheduler.current!
        now = scheduler.nextDeadline! + 0.01
        scheduler.advance(now: now)
        scheduler.update(id: id, source: "Hello. Next step.", translation: "你好。下一步。", final: true, now: now)
        let cues = [read] + drain(&scheduler, now: &now)
        XCTAssertEqual(cues.map(\.translation.raw).joined(), "你好。下一步。")
        XCTAssertEqual(cues.map(\.source.raw).joined(), "Hello. Next step.")
    }

    func testSixtySecondsOfRevisedCaptionsNeverReplayReadSentences() {
        var scheduler = CaptionScheduler()
        var now = 0.0
        var displayed = [String]()
        for index in 0..<20 {
            let id = UUID()
            let source = "Hello. Task \(index). Finished \(index)."
            scheduler.update(id: id, source: source, translation: "你好。第\(index)项。完成\(index)项。", final: false, now: now)
            displayed.append(scheduler.current!.translation.raw)
            now = scheduler.nextDeadline! + 0.01
            scheduler.advance(now: now)
            let currentID = scheduler.current?.id
            scheduler.update(id: id, source: source, translation: "您好。第\(index)项。完成\(index)项。", final: false, now: now + 0.1)
            XCTAssertEqual(scheduler.current?.source.raw, "Task \(index). ", "a revision must never rewind to Hello")
            XCTAssertEqual(scheduler.current?.translation.raw, "第\(index)项。")
            XCTAssertEqual(scheduler.current?.id, currentID, "the visible cue must not jump backwards")
            scheduler.update(id: id, source: source, translation: "您好。第\(index)项。完成\(index)项。", final: true, now: now + 0.2)
            let rest = drain(&scheduler, now: &now)
            displayed += rest.map(\.translation.raw)
            now += 1
        }
        XCTAssertGreaterThan(now, 60, "exercise a stream longer than the reported 40s onset")
        XCTAssertEqual(displayed.filter { $0 == "你好。" }.count, 20)
        XCTAssertFalse(displayed.contains("您好。"), "reworded greetings were already read")
        for index in 0..<20 {
            XCTAssertEqual(displayed.filter { $0 == "第\(index)项。" }.count, 1)
            XCTAssertEqual(displayed.filter { $0 == "完成\(index)项。" }.count, 1)
        }
    }

    func testLiveRewordingDoesNotLeaveNextCueWaitingUntilFinalization() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "Hello. How are you?", translation: "你好。", final: false, now: 0)
        scheduler.advance(now: scheduler.nextDeadline! + 0.01)
        XCTAssertEqual(scheduler.current?.source.raw, "How are you?")
        XCTAssertEqual(scheduler.current?.translation.raw, "")
        // A new rolling ASR translation revises an ALREADY READ prefix.
        // It must reach the display before the VAD segment finally ends.
        scheduler.update(id: id, source: "Hello. How are you?", translation: "您好。你好吗？", final: false, now: 1)
        XCTAssertFalse(scheduler.current?.translation.raw.isEmpty ?? true,
                       "completed revised text must not be held until silence / the 15s VAD limit")
        XCTAssertEqual(scheduler.current?.translation.raw, "你好吗？")
        XCTAssertEqual(scheduler.current?.source.raw, "How are you?", "never rewind the paired source")
        scheduler.update(id: id, source: "Hello. How are you?", translation: "您好。你好吗？", final: true, now: 1.1)
        var now = 1.1
        let corrected = drain(&scheduler, now: &now)
        XCTAssertEqual(corrected.map(\.source.raw).joined(), "How are you?")
        XCTAssertEqual(corrected.map(\.translation.raw).joined(), "你好吗？")
    }

    func testReplacementTokenPrefixDoesNotRewindReadCaptionPrematurely() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "Hello. How are you?", translation: "你好。", final: false, now: 0)
        scheduler.advance(now: scheduler.nextDeadline! + 0.01)
        let previous = scheduler.current
        scheduler.update(id: id, source: "Hello. How are you?", translation: "您", final: false, now: 1)
        XCTAssertEqual(scheduler.current?.source, previous?.source)
        XCTAssertEqual(scheduler.current?.translation, previous?.translation)
    }

    func testFinalCorrectionUpdatesUnreadPageWithoutReplayingReadText() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "One. Two.", translation: "第一。第二。", final: false, now: 0)
        var now = scheduler.nextDeadline! + 0.01
        scheduler.advance(now: now)
        scheduler.update(id: id, source: "One. Three.", translation: "修正第一。第三。", final: true, now: now)
        XCTAssertTrue(scheduler.current?.isCorrection == true)
        let cues = drain(&scheduler, now: &now)
        XCTAssertEqual(cues.map(\.translation.raw).joined(), "第三。")
        XCTAssertEqual(cues.map(\.source.raw).joined(), "Three.")
    }

    func testFinalizationReleasesAnAlreadyReadLiveHead() {
        var scheduler = CaptionScheduler()
        let a = UUID(), b = UUID()
        scheduler.update(id: a, source: "One.", translation: "第一。", final: false, now: 0)
        scheduler.update(id: b, source: "Two.", translation: "第二。", final: true, now: 0)
        var now = scheduler.nextDeadline! + 0.01
        scheduler.advance(now: now)
        XCTAssertNil(scheduler.current)
        scheduler.update(id: a, source: "One.", translation: "第一。", final: true, now: now)
        XCTAssertEqual(scheduler.current?.utteranceID, b)
        _ = drain(&scheduler, now: &now)
        scheduler.update(id: a, source: "One.", translation: "第一。", final: true, now: now)
        XCTAssertFalse(scheduler.isDraining, "a duplicate completion cannot replay an old sentence")
    }

    func testSourceFirstWaitsForTranslationAndPauseDrainsSourceOnly() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        let source = "First sentence. Second sentence. Third sentence."
        scheduler.update(id: id, source: source, translation: nil, final: false, now: 0)
        XCTAssertEqual(scheduler.current?.source.raw, "First sentence. ")
        XCTAssertNil(scheduler.nextDeadline)
        scheduler.finishPending(now: 0)
        var now = 0.0
        let cues = drain(&scheduler, now: &now)
        XCTAssertEqual(cues.map(\.source.raw).joined(), source)
    }

    func testLargerFontsAndHiddenSourceDoNotDropTextOrAddBlankPages() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        let source = String(repeating: "A very long source with many words ", count: 10)
        let translation = "精简译文。"
        scheduler.update(id: id, source: source, translation: translation, final: true, now: 0)
        scheduler.reflow(CaptionTypography(width: 392, translationSize: 40, showsSource: false), now: 0.5)
        var now = 0.5
        let cues = drain(&scheduler, now: &now)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.map(\.source.raw).joined(), source)
        XCTAssertEqual(cues.map(\.translation.raw).joined(), translation)
    }

    func testReadingTimeGrowsWithTextAndLateTokensGetTimeToRead() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "", translation: "你好", final: false, now: 0)
        scheduler.update(id: id, source: "", translation: "你好，欢迎参加今天的项目预算审查会议。", final: true, now: 5)
        XCTAssertGreaterThanOrEqual(scheduler.nextDeadline!, 5.25)
        scheduler.advance(now: 5.1)
        XCTAssertNotNil(scheduler.current)
    }

    func testRewordedVisibleCueGetsFreshReadingTime() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "", translation: "原来的说法。", final: false, now: 0)
        scheduler.update(id: id, source: "", translation: "最终修正之后这句话需要重新给读者留足阅读时间。", final: true, now: 10)
        XCTAssertGreaterThanOrEqual(scheduler.nextDeadline!, 10.75)
        XCTAssertLessThanOrEqual(scheduler.nextDeadline!, 12.4)
        scheduler.advance(now: 11)
        XCTAssertNotNil(scheduler.current)
    }

    func testFinishingAbandonedLiveSegmentUnblocksFollowingCaptions() {
        var scheduler = CaptionScheduler()
        let a = UUID(), b = UUID()
        scheduler.update(id: a, source: "Unfinished recognition.", translation: nil, final: false, now: 0)
        scheduler.update(id: b, source: "Next.", translation: "下一句。", final: true, now: 0)
        scheduler.finish(id: a, now: 0)
        var now = 0.0
        let cues = drain(&scheduler, now: &now)
        XCTAssertEqual(cues.first?.source.raw, "Unfinished recognition.")
        XCTAssertEqual(cues.last?.translation.raw, "下一句。")
    }

    func testFontChangeAfterDrainRepaginatesRetainedTextWithoutCropping() {
        var scheduler = CaptionScheduler()
        let text = "这段完整字幕需要在字号变大以后依然能够完整显示"
        scheduler.update(id: UUID(), source: "", translation: text, final: true, now: 0)
        var now = 0.0
        _ = drain(&scheduler, now: &now)
        scheduler.reflow(CaptionTypography(width: 392, translationSize: 40), now: now)
        let cues = drain(&scheduler, now: &now)
        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertEqual(cues.map(\.translation.raw).joined(), text)
    }

    @MainActor
    func testPresenterTimerAdvancesWithoutNewInput() async throws {
        let presenter = CaptionPresenter()
        presenter.update(id: UUID(), source: "", translation: "第一句。第二句。", final: true)
        XCTAssertEqual(presenter.visible?.translation.raw, "第一句。")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(presenter.visible?.translation.raw, "第二句。")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(presenter.isDraining)
        presenter.reset()
        XCTAssertNil(presenter.visible)
    }
}
