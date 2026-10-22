import XCTest
@testable import Ora

final class ListeningSessionTests: XCTestCase {
    private func entry(session: UUID, text: String = "Hello", date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> TranscriptEntry {
        TranscriptEntry(id: UUID(), startedAt: date, endedAt: date, sourceText: text, translationText: "你好",
                        sourceLanguageHint: "en", targetLanguage: "Chinese", audioSource: "systemAudio", sessionId: session)
    }

    func testDurationAndEmptyReceiptNeverClaimASave() {
        for (seconds, expected) in [(0.2, "<1s"), (12.9, "12s"), (125.0, "2m 5s"), (3661.0, "1h 1m 1s")] {
            let summary = SessionSummary(id: UUID(), duration: seconds, savedLines: 0, unfinishedLines: 0)
            XCTAssertEqual(summary.durationText, expected)
            XCTAssertFalse(SessionNotice.empty(summary).title.contains("saved"))
            XCTAssertEqual(SessionNotice.empty(summary).detail, "No recognized speech to save")
        }
    }

    func testOnlyUnfinishedUtteranceIsSnapshottedAndNeverPairsWithPreviousTranslation() {
        var session = ListeningSession(id: UUID())
        let first = UUID(), second = UUID()
        session.update(utteranceID: first, source: "Hello", translation: "你好", target: "Chinese", sourceLanguage: "en", audioSource: "systemAudio")
        session.committed(utteranceID: first)
        XCTAssertNil(session.unfinishedEntry(endedAt: Date()))
        XCTAssertEqual(session.completedCount, 1)
        session.update(utteranceID: second, source: "Next sentence", translation: nil,
                       target: "Chinese", sourceLanguage: "en", audioSource: "systemAudio")
        let unfinished = session.unfinishedEntry(endedAt: Date())
        XCTAssertEqual(unfinished?.id, second)
        XCTAssertEqual(unfinished?.sessionId, session.id)
        XCTAssertEqual(unfinished?.translationText, "")
        XCTAssertEqual(unfinished?.isPartial, true)
        XCTAssertEqual(session.completedCount, 1)
    }

    func testLatestPartialTranslationAndSourceArePreservedOnEnd() {
        var session = ListeningSession(id: UUID())
        let id = UUID()
        session.update(utteranceID: id, source: "Hello", translation: "你好", target: "Chinese", sourceLanguage: nil, audioSource: "microphone")
        session.update(utteranceID: id, source: "Hello everyone", translation: nil, target: "Chinese", sourceLanguage: nil, audioSource: "microphone")
        let endedAt = Date()
        let unfinished = session.unfinishedEntry(endedAt: endedAt)
        XCTAssertEqual(unfinished?.sourceText, "Hello everyone")
        XCTAssertEqual(unfinished?.translationText, "你好")
        XCTAssertEqual(unfinished?.endedAt, endedAt)
        XCTAssertEqual(unfinished?.isPartial, true)
    }

    func testOldJSONLWithoutPartialFlagStillLoads() throws {
        let original = entry(session: UUID())
        let data = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("isPartial"))
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.isPartial)
    }

    @MainActor
    func testFlushMakesAllQueuedWritesReadableAndNewStartsCreateSeparateSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-session-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let first = UUID(), second = UUID()
        history.beginSession(id: first)
        for n in 0..<20 { history.append(entry(session: first, text: "First \(n)")) }
        try await history.flush(sessionID: first)
        XCTAssertEqual(history.loadAll().count, 20)
        history.beginSession(id: second)
        XCTAssertTrue(history.currentSession.isEmpty)
        history.append(entry(session: second, text: "Second session"))
        try await history.flush(sessionID: second)
        XCTAssertEqual(history.currentSession.count, 1)
        XCTAssertEqual(history.currentSession.first?.sessionId, second)
        XCTAssertEqual(history.inMemoryEntries.count, 21)
        XCTAssertEqual(Set(history.loadAll().map(\.sessionId)), [first, second])
    }

    @MainActor
    func testWriteFailureIsReportedAndTranscriptRemainsRecoverableAcrossStarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-session-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockingFile = directory.appendingPathComponent("not-a-folder")
        try Data("blocked".utf8).write(to: blockingFile)
        let history = TranscriptHistory(directory: blockingFile.appendingPathComponent("history"))
        let id = UUID()
        history.beginSession(id: id)
        history.append(entry(session: id))
        do {
            try await history.flush(sessionID: id)
            XCTFail("an actual disk failure must not produce a success receipt")
        } catch {
            XCTAssertEqual(history.inMemoryEntries.count, 1)
        }
        history.beginSession(id: UUID())
        XCTAssertEqual(history.inMemoryEntries.count, 1, "unsaved transcripts remain available in History")
    }

    func testSaveErrorsAreScopedToTheCorrectSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-writer-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockingFile = directory.appendingPathComponent("blocked")
        try Data().write(to: blockingFile)
        let writer = TranscriptFileWriter()
        let failed = UUID(), valid = UUID()
        writer.append(entry(session: failed), to: blockingFile.appendingPathComponent("history.jsonl"))
        writer.append(entry(session: valid), to: directory.appendingPathComponent("history.jsonl"))
        try await writer.flush(sessionID: valid)
        do {
            try await writer.flush(sessionID: failed)
            XCTFail("the failed session must still report its own write error")
        } catch {}
    }

    @MainActor
    func testStartAndStopClearBothRawTextAndQueuedCaptionsImmediately() async throws {
        let engine = TranslatorEngine()
        func seedText() {
            engine.sourceText = "Old speech"
            engine.translationText = "旧字幕"
            engine.captions.update(id: UUID(), source: "Old speech", translation: "旧字幕。还有下一页。", final: true)
        }
        engine.phase = .listening
        seedText()
        engine.stop()
        XCTAssertEqual(engine.phase, .ready)
        XCTAssertEqual(engine.sourceText, "")
        XCTAssertEqual(engine.translationText, "")
        XCTAssertNil(engine.captions.visible)
        XCTAssertFalse(engine.captions.isDraining)
        seedText()
        engine.sessionNotice = .saved(SessionSummary(id: UUID(), duration: 125, savedLines: 1, unfinishedLines: 0))
        // No models are installed on this engine, so start returns before
        // touching microphone/system capture. The button still clears now.
        engine.toggle()
        XCTAssertEqual(engine.sourceText, "")
        XCTAssertEqual(engine.translationText, "")
        XCTAssertNil(engine.captions.visible)
        XCTAssertNil(engine.sessionNotice)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertNil(engine.captions.visible, "a cancelled page timer cannot restore old text")
    }
}
