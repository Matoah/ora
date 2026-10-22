import XCTest
@testable import Ora

final class LiveCaptionTests: XCTestCase {
    func testReplacementDoesNotEraseReadableWordsWhileCatchingUp() {
        var revision = CaptionRevision(previous: "你好，欢迎参加会议。")
        XCTAssertEqual(revision.update("你"), "你好，欢迎参加会议。")
        XCTAssertEqual(revision.update("你好，欢迎参加会议。今天"), "你好，欢迎参加会议。今天")
        XCTAssertEqual(revision.update("你好，欢迎参加会议。今天讨论预算。"), "你好，欢迎参加会议。今天讨论预算。")
    }

    func testNewUtteranceStreamsFromFirstToken() {
        var revision = CaptionRevision(previous: "")
        XCTAssertEqual(revision.update("你好"), "你好")
        XCTAssertEqual(revision.update("你好世界"), "你好世界")
    }

    func testRecognitionAgreementDoesNotLockAnIncompleteWord() {
        var source = LiveSourceText()
        source.update("We need a car")
        XCTAssertEqual(source.stablePrefix, "")
        source.update("We need a carpet")
        XCTAssertEqual(source.stablePrefix, "We need a ")
        XCTAssertEqual(source.tentativeSuffix, "carpet")
        source.update("We need a carpet today")
        XCTAssertEqual(source.stablePrefix, "We need a carpet")
        source.commit("We need a carpet today.")
        XCTAssertEqual(source.tentativeSuffix, "")
    }

    func testCJKAgreementAndCorrections() {
        var source = LiveSourceText()
        source.update("今天下午开会")
        source.update("今天下午开会讨论预算")
        XCTAssertEqual(source.stablePrefix, "今天下午开会")
        source.update("今天上午开会讨论预算")
        XCTAssertEqual(source.stablePrefix, "今天")
        XCTAssertEqual(source.stablePrefix + source.tentativeSuffix, source.text)
    }

    func testSourceAppearsBeforeTranslationAndTokensAppearBeforeCompletion() async {
        let sourceDrawn = expectation(description: "source available before any translated token")
        let tokenDrawn = expectation(description: "first translated token visible before stream completion")
        let backend = ControlledCaptionBackend()
        let log = CaptionDrawLog()
        let utteranceID = UUID()
        let pipe = PartialPipeline(transcribe: { _ in "Hello world" }, backend: backend) { source, translation, id in
            XCTAssertEqual(id, utteranceID, "source and all streamed chunks must update the same utterance")
            await log.append(source, translation)
            if translation == nil { sourceDrawn.fulfill() }
            if translation == "你好" { tokenDrawn.fulfill() }
        }
        await pipe.start()
        await pipe.submit([1], id: utteranceID)
        await fulfillment(of: [sourceDrawn, backend.requestStarted], timeout: 3)
        let beforeTokens = await log.translations
        XCTAssertEqual(beforeTokens.count, 1)
        XCTAssertNil(beforeTokens[0])

        backend.yield("你好")
        await fulfillment(of: [tokenDrawn], timeout: 3)
        backend.yield("世界")
        backend.finish()
        await pipe.awaitQuiescence()
        let translations = await log.translations
        XCTAssertEqual(translations.compactMap { $0 }, ["你好", "你好世界"])
        await pipe.shutdown()
    }

    func testLiveTranslationUsesTheSameCommittedContextAsFinals() async {
        let context = TranslationContext()
        context.note(source: "The dishwasher is broken.", translation: "洗碗机坏了。")
        let backend = ControlledCaptionBackend()
        let pipe = PartialPipeline(transcribe: { _ in "Please fix it." }, backend: backend, context: context) { _, _, _ in }
        await pipe.start()
        await pipe.submit([1])
        await fulfillment(of: [backend.requestStarted], timeout: 3)
        XCTAssertEqual(backend.receivedHistory(), context.snapshot())
        backend.yield("请修好它。")
        backend.finish()
        await pipe.awaitQuiescence()
        await pipe.shutdown()
    }

    func testFreezeCancelsStreamAndCannotPaintAfterReset() async {
        let backend = ControlledCaptionBackend()
        let log = CaptionDrawLog()
        let sourceDrawn = expectation(description: "source drawn")
        let pipe = PartialPipeline(transcribe: { _ in "Hello" }, backend: backend) { source, translation, _ in
            await log.append(source, translation)
            if translation == nil { sourceDrawn.fulfill() }
        }
        await pipe.start()
        await pipe.submit([1])
        await fulfillment(of: [sourceDrawn, backend.requestStarted], timeout: 3)
        let generation = await pipe.freeze()
        await pipe.awaitQuiescence()
        let count = await log.translations.count
        await pipe.reset(ifGeneration: generation)
        backend.yield("STALE")
        backend.finish()
        await pipe.awaitQuiescence()
        let after = await log.translations.count
        XCTAssertEqual(after, count)
        await pipe.shutdown()
    }

    func testShutdownRejectsInFlightRecognition() async {
        let recognitionStarted = expectation(description: "recognition started")
        let recognizer = SuspendedCaptionRecognizer()
        let log = CaptionDrawLog()
        let backend = ControlledCaptionBackend()
        let pipe = PartialPipeline(transcribe: { _ in
            await recognizer.wait(started: recognitionStarted)
        }, backend: backend) { source, translation, _ in
            await log.append(source, translation)
        }
        await pipe.start()
        await pipe.submit([1])
        await fulfillment(of: [recognitionStarted], timeout: 3)
        await pipe.shutdown()
        await recognizer.finish()
        await pipe.awaitQuiescence()
        let count = await log.translations.count
        XCTAssertEqual(count, 0)
    }
}

private actor CaptionDrawLog {
    var translations: [String?] = []
    func append(_ source: String, _ translation: String?) { translations.append(translation) }
}

private actor SuspendedCaptionRecognizer {
    private var continuation: CheckedContinuation<String, Never>?
    func wait(started: XCTestExpectation) async -> String {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish() { continuation?.resume(returning: "Old session"); continuation = nil }
}

private final class ControlledCaptionBackend: TranslationBackend, @unchecked Sendable {
    var targetLanguage = "Chinese"
    let requestStarted = XCTestExpectation(description: "translation stream requested")
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var history: [TranslationExchange] = []

    func receivedHistory() -> [TranslationExchange] { lock.withLock { history } }

    func translate(_ text: String) async throws -> String {
        XCTFail("Live captions must use streaming translation")
        return ""
    }

    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        lock.withLock { continuation = pair.continuation; self.history = history }
        requestStarted.fulfill()
        return pair.stream
    }

    func yield(_ text: String) { lock.withLock { _ = continuation?.yield(text) } }
    func finish() { lock.withLock { continuation?.finish() } }
}
