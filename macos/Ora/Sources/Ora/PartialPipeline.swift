import Foundation

/// Background worker that processes the latest partial audio snapshot into a
/// streamed translation. Publishes recognition immediately, before waiting
/// for the translator, then publishes each translated chunk as it arrives.
///
/// The UI-facing variant is aliased as `PartialPipelineUI` for clarity at
/// call sites in TranslatorEngine.
actor PartialPipeline {
    // nil means recognition only; keep the last readable translation visible.
    typealias DrawCallback = @Sendable (_ source: String, _ translated: String?, _ utteranceID: UUID) async -> Void

    /// Cap on how long the finals worker will wait for in-flight partial
    /// inference — a hung partial (stalled server, runaway generation) must
    /// not stall final captions forever. Mirrors main.py's wait_quiescent.
    static let quiescenceTimeout: Duration = .seconds(10)

    private let transcribe: @Sendable ([Float]) async -> String
    private let backend: any TranslationBackend
    private let context: TranslationContext?
    private let drawPartial: DrawCallback

    private var latest: CapturedUtterance?
    private var frozen = false
    /// Bumped on every freeze. reset(ifGeneration:) uses it to no-op when a
    /// newer freeze (= a newer final) arrived after the caller decided to
    /// reset, so a late reset can never unfreeze someone else's freeze.
    private var freezeGeneration = 0
    private var lastText = ""
    private var workerTask: Task<Void, Never>?
    private var inferenceTask: Task<Void, Never>?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var processing = false

    private final class QuiescenceWaiter {
        var continuation: CheckedContinuation<Void, Never>?
    }
    private var quiescenceWaiters: [QuiescenceWaiter] = []

    init(asr: ASRClient, backend: any TranslationBackend, context: TranslationContext? = nil, drawPartial: @escaping DrawCallback) {
        self.transcribe = { await asr.transcribe($0) }
        self.backend = backend
        self.context = context
        self.drawPartial = drawPartial
    }

    /// Same pipeline with an injected recognizer for deterministic timing tests.
    init(transcribe: @escaping @Sendable ([Float]) async -> String,
         backend: any TranslationBackend, context: TranslationContext? = nil, drawPartial: @escaping DrawCallback) {
        self.transcribe = transcribe
        self.backend = backend
        self.context = context
        self.drawPartial = drawPartial
    }

    func start() {
        // Pure wake signal — processOne() always reads the latest snapshot, so
        // coalescing redundant wakeups to a single pending token is correct and
        // avoids spinning through stale signals when submits outpace the worker.
        let wake = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.wakeContinuation = continuation
        }
        workerTask = Task { [weak self] in
            guard let self else { return }
            for await _ in wake {
                if Task.isCancelled { return }
                await self.runNext()
            }
        }
    }

    private func runNext() async {
        let task = Task { await self.processOne() }
        inferenceTask = task
        await task.value
        inferenceTask = nil
    }

    func submit(_ audio: [Float], id: UUID = UUID()) {
        // While frozen this only stores the snapshot (it belongs to the next
        // utterance); reset() re-wakes the worker so it isn't lost.
        latest = CapturedUtterance(id: id, audio: audio)
        if !frozen {
            wakeContinuation?.yield(())
        }
    }

    /// Stop accepting new partial work immediately (fast — just a flag).
    /// `discardPending` drops the stored snapshot: true at final-dispatch time
    /// (the snapshot belongs to the utterance being finalized), false for the
    /// worker's defensive re-freeze (the snapshot belongs to the NEXT
    /// utterance and must survive until reset re-wakes it).
    /// Returns the new freeze generation for use with reset(ifGeneration:).
    @discardableResult
    func freeze(discardPending: Bool = true) -> Int {
        frozen = true
        if discardPending {
            latest = nil
        }
        freezeGeneration += 1
        // Stop token generation so the final needn't wait for an entire
        // speculative translation. Synchronous ASR still finishes safely.
        inferenceTask?.cancel()
        return freezeGeneration
    }

    var generation: Int { freezeGeneration }

    /// Wait until no partial ASR/translate is in flight (bounded by
    /// `quiescenceTimeout`). Separate from `freeze()` so the (fast) dispatch
    /// loop never blocks on inference; only the finals worker pays the wait.
    func awaitQuiescence() async {
        let deadline = ContinuousClock.now + Self.quiescenceTimeout
        while processing {
            if ContinuousClock.now >= deadline { return }
            let waiter = QuiescenceWaiter()
            quiescenceWaiters.append(waiter)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiter.continuation = c
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    await self?.expire(waiter)
                }
            }
        }
    }

    /// Timeout path: release one waiter even though work is still in flight.
    private func expire(_ waiter: QuiescenceWaiter) {
        guard let c = waiter.continuation else { return }
        waiter.continuation = nil
        quiescenceWaiters.removeAll { $0 === waiter }
        c.resume()
    }

    /// Unfreeze — but only if no newer freeze happened since `expected` was
    /// observed. Re-wakes the worker if a next-utterance snapshot is pending.
    func reset(ifGeneration expected: Int) {
        guard freezeGeneration == expected else { return }
        frozen = false
        lastText = ""
        if latest != nil {
            wakeContinuation?.yield(())
        }
    }

    func shutdown() {
        frozen = true
        freezeGeneration += 1
        latest = nil
        inferenceTask?.cancel()
        wakeContinuation?.finish()
        workerTask?.cancel()
    }

    private func processOne() async {
        guard !frozen, let utterance = latest else { return }
        latest = nil
        let generationAtStart = freezeGeneration

        processing = true
        let startedAt = ContinuousClock.now
        var asrDoneAt: ContinuousClock.Instant?
        var firstTokenAt: ContinuousClock.Instant?
        var outcome = "superseded"
        defer {
            let endedAt = ContinuousClock.now
            func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Int {
                let d = start.duration(to: end).components
                return Int(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
            }
            // Slow-path diagnostics only; never log recognized speech.
            if ms(startedAt, endedAt) >= 750 {
                let asrMS = asrDoneAt.map { ms(startedAt, $0) } ?? -1
                let firstMS = firstTokenAt.flatMap { first in asrDoneAt.map { ms($0, first) } } ?? -1
                let status = Task.isCancelled ? "cancelled" : outcome
                let report = "[partial-latency] asr_ms=\(asrMS) first_token_ms=\(firstMS) total_ms=\(ms(startedAt, endedAt)) status=\(status)\n"
                FileHandle.standardError.write(Data(report.utf8))
            }
            processing = false
            let waiters = quiescenceWaiters
            quiescenceWaiters.removeAll()
            for waiter in waiters {
                if let c = waiter.continuation {
                    waiter.continuation = nil
                    c.resume()
                }
            }
        }

        let text = await transcribe(utterance.audio)
        asrDoneAt = .now
        guard !Task.isCancelled, !frozen, freezeGeneration == generationAtStart,
              !text.isEmpty, text != lastText else { return }
        await drawPartial(text, nil, utterance.id)
        guard !Task.isCancelled, !frozen, freezeGeneration == generationAtStart else { return }

        do {
            var translated = ""
            for try await chunk in backend.translateStream(text, history: context?.snapshot() ?? []) {
                guard !Task.isCancelled, !frozen,
                      freezeGeneration == generationAtStart else { return }
                if firstTokenAt == nil, !chunk.isEmpty { firstTokenAt = .now }
                translated += chunk
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                await drawPartial(text, translated, utterance.id)
            }
            guard !Task.isCancelled, !frozen, freezeGeneration == generationAtStart else { return }
            // Only deduplicate successful work; transient failures must retry
            // even when the next ASR snapshot contains identical words.
            if !translated.isEmpty { lastText = text }
            outcome = "completed"
        } catch {
            outcome = "failed"
            // Silent failure for partials — next audio update will retry.
        }
    }
}

/// Alias used by TranslatorEngine so the UI vs CLI intent is explicit.
typealias PartialPipelineUI = PartialPipeline
