import Foundation

/// Tracks only the latest unfinished utterance. Completed utterances are
/// already appended to history and must never be duplicated on Stop.
struct ListeningSession {
    let id: UUID
    let startedAt: Date
    let clockStart: ContinuousClock.Instant
    private(set) var pending: TranscriptEntry?
    private(set) var completedCount = 0

    init(id: UUID, startedAt: Date = Date(), clockStart: ContinuousClock.Instant = .now) {
        self.id = id
        self.startedAt = startedAt
        self.clockStart = clockStart
    }

    mutating func update(utteranceID: UUID, source: String, translation: String?,
                         target: String, sourceLanguage: String?, audioSource: String, now: Date = Date()) {
        let prior = pending?.id == utteranceID ? pending : nil
        pending = TranscriptEntry(id: utteranceID, startedAt: prior?.startedAt ?? now, endedAt: now,
                                  sourceText: source, translationText: translation ?? prior?.translationText ?? "",
                                  sourceLanguageHint: sourceLanguage, targetLanguage: target,
                                  audioSource: audioSource, sessionId: id, isPartial: true)
    }

    mutating func committed(utteranceID: UUID) {
        completedCount += 1
        if pending?.id == utteranceID { pending = nil }
    }

    func unfinishedEntry(endedAt: Date) -> TranscriptEntry? {
        guard let pending,
              !pending.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pending.translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TranscriptEntry(id: pending.id, startedAt: pending.startedAt, endedAt: endedAt,
                               sourceText: pending.sourceText, translationText: pending.translationText,
                               sourceLanguageHint: pending.sourceLanguageHint, targetLanguage: pending.targetLanguage,
                               audioSource: pending.audioSource, sessionId: id, isPartial: true)
    }
}

struct SessionSummary: Equatable {
    let id: UUID
    let duration: TimeInterval
    let savedLines: Int
    let unfinishedLines: Int

    var durationText: String {
        let seconds = max(0, Int(duration.rounded(.down)))
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m \(seconds % 60)s"
    }
}

enum SessionNotice: Equatable {
    case saving(SessionSummary)
    case saved(SessionSummary)
    case empty(SessionSummary)
    case failed(SessionSummary, String)

    var title: String {
        switch self {
        case .saving: return "Saving session…"
        case .saved(let summary): return "Session saved · \(summary.durationText)"
        case .empty(let summary): return "Session ended · \(summary.durationText)"
        case .failed: return "Session could not be saved"
        }
    }

    var detail: String {
        switch self {
        case .saving: return "Writing transcript to local history"
        case .saved(let summary):
            let lines = "\(summary.savedLines) \(summary.savedLines == 1 ? "line" : "lines") saved locally"
            return summary.unfinishedLines > 0 ? "\(lines) · \(summary.unfinishedLines) unfinished" : lines
        case .empty: return "No recognized speech to save"
        case .failed: return "Transcript kept in memory. Open history to export."
        }
    }
}
