import AppKit

struct ScheduledCaption: Equatable, Identifiable {
    var id = UUID()
    let utteranceID: UUID
    var source: CaptionSlice
    var translation: CaptionSlice
    var isDraft: Bool
    var isCorrection = false
}

/// A text-only FIFO. It never drops completed captions to catch up with audio.
/// Tests supply a virtual monotonic clock; production uses ContinuousClock.
struct CaptionScheduler {
    private struct Utterance {
        let id: UUID
        var sourceTrack = CaptionTextTrack()
        var translationTrack = CaptionTextTrack()
        var final = false
        var lastSourcePage = ""
        var lastTranslationPage = ""
        var source: String { sourceTrack.text }
        var translation: String { translationTrack.text }
        var consumedSource: String { sourceTrack.consumed }
        var consumedTranslation: String { translationTrack.consumed }
    }

    var typography = CaptionTypography()
    private var queue: [Utterance] = []
    private var completed: Set<UUID> = []
    private(set) var current: ScheduledCaption?
    private(set) var retained: ScheduledCaption?
    private var startedAt: TimeInterval = 0
    private var firstShownAt: TimeInterval = 0
    private var changedAt: TimeInterval = 0
    var visible: ScheduledCaption? { current ?? retained }
    var queuedUtteranceCount: Int { max(0, queue.count - 1) }
    var isDraining: Bool { !queue.isEmpty }

    mutating func update(id: UUID, source: String, translation: String?, final: Bool, now: TimeInterval) {
        guard !completed.contains(id) else { return }
        if !queue.contains(where: { $0.id == id }) {
            queue.append(Utterance(id: id))
        }
        let index = queue.firstIndex { $0.id == id }!
        var item = queue[index]
        let oldSource = item.sourceTrack.remaining
        let oldTranslation = item.translationTrack.remaining
        item.sourceTrack.update(source, final: final)
        if let translation { item.translationTrack.update(translation, final: final) }
        let correction = (!oldSource.isEmpty && !item.sourceTrack.remaining.hasPrefix(oldSource))
            || (!oldTranslation.isEmpty && !item.translationTrack.remaining.hasPrefix(oldTranslation))
        item.final = item.final || final
        queue[index] = item
        if index == 0 {
            render(now: now, correction: correction)
            advance(now: now)
        }
    }

    /// Reflow only the unread page when preferences change. Read offsets stay
    /// in original text coordinates, so no text disappears at a new font size.
    mutating func reflow(_ typography: CaptionTypography, now: TimeInterval) {
        guard self.typography != typography else { return }
        self.typography = typography
        if queue.isEmpty, let retained {
            var item = Utterance(id: retained.utteranceID)
            item.sourceTrack.update(retained.source.raw, final: true)
            item.translationTrack.update(retained.translation.raw, final: true)
            item.final = true
            queue.append(item)
            completed.remove(retained.utteranceID)
        }
        current = nil
        render(now: now)
    }

    var nextDeadline: TimeInterval? {
        guard let cue = current, let item = queue.first else { return nil }
        let sourceDone = item.consumedSource.count + cue.source.raw.count >= item.source.count
        let translationDone = item.consumedTranslation.count + cue.translation.raw.count >= item.translation.count
        let hasMore = !sourceDone || !translationDone || queue.count > 1
        // Never page recognized words ahead while their translation is still
        // empty. At final/error/stop, a source-only cue can still drain.
        guard item.final || (!cue.translation.raw.isEmpty && cue.translation.sealed && hasMore) else { return nil }
        let translationTime = CaptionPaginator.readingUnits(cue.translation.raw)
        // Meeting captions prioritize the translation. A verbose source
        // must not hold a short translated cue for five seconds.
        let effort = cue.translation.raw.isEmpty ? CaptionPaginator.readingUnits(cue.source.raw) : translationTime
        let dwell = max(0.75, min(2.4, effort * 0.6 + 0.15))
        let deadline = max(startedAt + dwell, changedAt + 0.25)
        guard hasMore else { return deadline }
        // Repeated ASR/LLM revisions cannot restart the wait indefinitely.
        // Shorten dwell under pressure, but still visit EVERY unread page.
        let backlog = queue.reduce(0.0) { result, entry in
            let remaining = String(entry.translation.dropFirst(entry.consumedTranslation.count))
            return result + CaptionPaginator.readingUnits(remaining)
        }
        let maximumHold: Double = queue.count > 1 || backlog >= 12 ? 1.2 : backlog >= 6 ? 1.8 : 2.4
        return min(deadline, firstShownAt + maximumHold)
    }

    mutating func advance(now: TimeInterval) {
        guard let deadline = nextDeadline, now >= deadline, let cue = current, !queue.isEmpty else { return }
        var item = queue[0]
        item.sourceTrack.consume(cue.source.raw)
        item.translationTrack.consume(cue.translation.raw)
        if !cue.source.raw.isEmpty { item.lastSourcePage = cue.source.raw }
        if !cue.translation.raw.isEmpty { item.lastTranslationPage = cue.translation.raw }
        retained = cue
        current = nil
        let done = item.consumedSource.count == item.source.count && item.consumedTranslation.count == item.translation.count
        if done && item.final {
            completed.insert(item.id)
            queue.removeFirst()
        } else {
            queue[0] = item
        }
        render(now: now)
    }

    /// Pause capture but finish reading text already received. Aborted model
    /// output stays a draft in history; presentation alone is allowed to drain.
    mutating func finishPending(now: TimeInterval) {
        for i in queue.indices { queue[i].final = true }
        render(now: now)
    }

    mutating func finish(id: UUID, now: TimeInterval) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].final = true
        if index == 0 { render(now: now) }
    }

    private mutating func render(now: TimeInterval, correction: Bool = false) {
        while let first = queue.first, first.final,
              first.consumedSource == first.source, first.consumedTranslation == first.translation {
            completed.insert(first.id)
            if retained?.utteranceID == first.id { retained?.isDraft = false }
            queue.removeFirst()
            current = nil
        }
        guard let item = queue.first else { current = nil; return }
        let src = String(item.source.dropFirst(item.consumedSource.count))
        let dst = String(item.translation.dropFirst(item.consumedTranslation.count))
        guard !src.isEmpty || !dst.isEmpty else {
            // A live stream can temporarily catch up to everything received.
            // Keep its last cue on screen until more text or finalization.
            current = nil
            return
        }
        let old = current?.utteranceID == item.id ? current : nil
        func slice(_ text: String, old: CaptionSlice?, font: NSFont) -> CaptionSlice {
            if let old, old.sealed, !old.raw.isEmpty, text.hasPrefix(old.raw) { return old }
            return CaptionPaginator.page(text, font: font, width: typography.width, lines: typography.lines, final: item.final)
        }
        func pairedSlice(_ text: String, held: String, old: CaptionSlice?, font: NSFont) -> CaptionSlice {
            guard text.isEmpty, !held.isEmpty else { return slice(text, old: old, font: font) }
            // The two languages need not have the same number of pages. Keep
            // context from THIS utterance visible while the other continues.
            // Empty raw means it is neither consumed twice nor re-queued.
            let context = CaptionPaginator.page(held, font: font, width: typography.width,
                                                lines: typography.lines, final: true)
            return CaptionSlice(raw: "", display: context.display, sealed: true)
        }
        let source = typography.showsSource
            ? pairedSlice(src, held: item.lastSourcePage, old: old?.source, font: typography.sourceFont)
            : CaptionSlice(raw: src, display: "", sealed: item.final)
        let translation = pairedSlice(dst, held: item.lastTranslationPage, old: old?.translation, font: typography.translationFont)
        let replacedWords = old.map { !source.raw.hasPrefix($0.source.raw) || !translation.raw.hasPrefix($0.translation.raw) } ?? false
        let firstTranslation = old?.translation.raw.isEmpty == true && !translation.raw.isEmpty
        // Appending tokens extends the existing reading clock. Rewording an
        // entire visible cue gives the reader a fresh dwell, not an 0.8s flash.
        if old == nil || firstTranslation { firstShownAt = now }
        if old == nil || firstTranslation || replacedWords { startedAt = now }
        if old?.source.display != source.display || old?.translation.display != translation.display { changedAt = now }
        current = ScheduledCaption(id: old?.id ?? UUID(), utteranceID: item.id, source: source,
                                   translation: translation, isDraft: !item.final,
                                   isCorrection: correction || old?.isCorrection == true)
    }
}
