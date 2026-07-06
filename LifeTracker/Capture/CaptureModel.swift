import Foundation
import Observation
import UIKit
import LifeTrackerCore

@MainActor
@Observable
final class CaptureModel {
    enum Phase: Equatable {
        case preparing
        case recording
        case processing
        case result                // shows what was added, with undo
        case fallback(String)      // voice unavailable → typed entry
    }

    /// One block the reconciliation created/changed, for the result card.
    struct AddedItem: Identifiable {
        let id: String
        let title: String
        let colorHex: String?
        let detail: String
        let needsTime: Bool   // times were guessed, not stated — worth a tap to fix
    }

    var phase: Phase = .preparing
    var preparingMessage = "Starting…"
    var liveText = ""
    var typedText = ""
    var resultMessage = ""
    var resultItems: [AddedItem] = []
    var level: Float = 0          // smoothed mic loudness (0…1) driving the listening orb
    var recordingSeconds = 0

    var canUndo: Bool { undoBatchId != nil }
    /// True when any block's times were inferred — the card then waits for the
    /// user instead of auto-dismissing, so a wrong guess is one tap to fix.
    var hasGuessedTimes: Bool { resultItems.contains { $0.needsTime } }

    private var undoBatchId: String?
    private var undoCheckInId: String?
    private var resultBatchId: String?
    private var timerTask: Task<Void, Never>?
    private let transcriber = SpeechTranscriberService()

    func begin(env: AppEnvironment) async {
        // Screenshot/demo hook: fake the listening state where the mic can't run.
        if ProcessInfo.processInfo.arguments.contains("-fakeListening") {
            liveText = "Done with the workout, finished at 7, now starting dinner"
            level = 0.55
            phase = .recording
            recordingSeconds = 8
            return
        }
        transcriber.onLevel = { [weak self] raw in
            Task { @MainActor in
                guard let self else { return }
                // Exponential smoothing so the orb swells and settles gently.
                self.level += (raw - self.level) * 0.35
            }
        }
        transcriber.onDownloadingAssets = { [weak self] in
            Task { @MainActor in self?.preparingMessage = "Downloading the on-device speech model…" }
        }
        // Phone call or mid-stream engine failure → wrap up with the text so far.
        transcriber.onStopped = { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                await self.finishRecording(env: env)
            }
        }
        do {
            try await transcriber.prepare()
            phase = .recording
            startTimer()
            haptic(.medium)
            try await transcriber.start { [weak self] text, _ in
                Task { @MainActor in self?.liveText = text }
            }
        } catch {
            phase = .fallback("Voice capture isn’t available — type your check-in instead.")
        }
    }

    func finishRecording(env: AppEnvironment) async {
        guard phase == .recording else { return }
        stopTimer()
        haptic(.light)
        phase = .processing
        let final = await transcriber.stop()
        let transcript = final.isEmpty ? liveText : final
        guard !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
            phase = .fallback("Didn’t catch that — type your check-in instead.")
            return
        }
        await ingest(transcript: transcript, method: .voice, engine: "speechanalyzer", env: env)
    }

    func submitTyped(env: AppEnvironment) async {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        phase = .processing
        await ingest(transcript: text, method: .typed, engine: "manual", env: env)
    }

    func cancel() async {
        stopTimer()
        await transcriber.cancelCapture()
    }

    /// Reverts the whole reconciliation batch and sends the check-in to the
    /// Unsorted inbox so the words aren't lost.
    func undo(env: AppEnvironment) {
        guard let batchId = undoBatchId else { return }
        try? EditService(env.database.dbWriter).undo(batchId: batchId, now: env.currentTime())
        if let checkInId = undoCheckInId {
            try? CheckInRepository(env.database.dbWriter)
                .setParseStatus(id: checkInId, .reparseNeeded, now: env.currentTime())
        }
        undoBatchId = nil
        CaptureLauncher.shared.changeToken = UUID()
        haptic(.rigid)
    }

    private func ingest(transcript: String, method: InputMethod, engine: String, env: AppEnvironment) async {
        let parser: TranscriptParser? = FoundationModelsParser.isAvailable ? FoundationModelsParser() : nil
        let service = CaptureService(dbWriter: env.database.dbWriter, parser: parser)
        let outcome = await service.ingest(
            transcript: transcript, inputMethod: method, sttEngine: engine,
            now: env.currentTime(), timeZone: env.timeZone
        )
        switch outcome {
        case .parsed(let checkInId, let batchId):
            resultMessage = "Added to your timeline"
            resultItems = Self.items(for: batchId, env: env)
            undoBatchId = batchId
            undoCheckInId = checkInId
            resultBatchId = batchId
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .manual:
            resultMessage = "Saved — structure it from Settings → Unsorted"
        case .failedParse:
            resultMessage = "Saved your words — couldn’t auto-structure this one"
        case .skipped:
            resultMessage = "Already added"
        }
        CaptureLauncher.shared.changeToken = UUID()
        env.rescheduleIdleReminder()
        phase = .result
    }

    /// Re-reads the card's blocks after an in-card edit.
    func refreshItems(env: AppEnvironment) {
        guard let batchId = resultBatchId else { return }
        resultItems = Self.items(for: batchId, env: env)
    }

    /// The blocks this batch touched, in day order (earliest start first, loose
    /// blocks last) — the card should read like the timeline will.
    private static func items(for batchId: String, env: AppEnvironment) -> [AddedItem] {
        let revs = (try? RevisionRepository(env.database.dbWriter).byBatch(batchId)) ?? []
        var catMap: [String: LifeTrackerCore.Category] = [:]
        for c in (try? CategoryRepository(env.database.dbWriter).live()) ?? [] { catMap[c.id] = c }
        let events = EventRepository(env.database.dbWriter)

        var seen = Set<String>()
        var found: [(item: AddedItem, sortKey: Int64)] = []
        for rev in revs {
            guard !seen.contains(rev.eventId),
                  let ev = (try? events.find(id: rev.eventId)) ?? nil else { continue }
            seen.insert(rev.eventId)
            let cat = ev.categoryId.flatMap { catMap[$0] }
            let guessed = ev.deletedAt == nil
                && ev.state == EventState.confirmed.rawValue
                && ev.confidence < 1.0
            found.append((
                AddedItem(
                    id: ev.id,
                    title: ev.title ?? cat?.name ?? "Untitled",
                    colorHex: cat?.colorHex,
                    detail: detail(for: ev, tz: env.timeZone),
                    needsTime: guessed
                ),
                ev.startAt ?? Int64.max
            ))
        }
        return found.sorted { $0.sortKey < $1.sortKey }.map(\.item)
    }

    private static func detail(for ev: Event, tz: TimeZone) -> String {
        if ev.deletedAt != nil { return "removed" }
        let planned = ev.state == EventState.planned.rawValue
        switch (ev.startAt, ev.endAt) {
        case let (s?, e?):
            let range = "\(TimeFormat.clock(s, tz: tz)) – \(TimeFormat.clock(e, tz: tz))"
            return planned ? "\(range) · planned" : range
        case let (s?, nil):
            return planned ? "\(TimeFormat.clock(s, tz: tz)) · planned" : "started \(TimeFormat.clock(s, tz: tz))"
        default:
            return planned ? "planned" : ""
        }
    }

    private func startTimer() {
        recordingSeconds = 0
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase == .recording else { return }
                self.recordingSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
