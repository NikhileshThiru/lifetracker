import Foundation
import GRDB

public enum CaptureOutcome: Sendable, Equatable {
    case parsed(checkInId: String, batchId: String)
    case failedParse(checkInId: String, error: String)
    case manual(checkInId: String)   // AI unavailable → user structures by hand
    case skipped(checkInId: String, reason: String)  // e.g. re-parse of an already-structured check-in
}

/// Orchestrates one captured check-in: always persist the raw transcript, then
/// (if a parser is available) parse → record the parse run → reconcile into the
/// timeline. With no parser, the transcript is stored for manual structuring.
public struct CaptureService {
    let dbWriter: any DatabaseWriter
    let parser: TranscriptParser?

    public init(dbWriter: any DatabaseWriter, parser: TranscriptParser?) {
        self.dbWriter = dbWriter
        self.parser = parser
    }

    public func ingest(
        transcript: String,
        inputMethod: InputMethod,
        sttEngine: String,
        now: Int64 = Clock.nowMillis(),
        timeZone: TimeZone = .current,
        userId: String? = nil
    ) async -> CaptureOutcome {
        let checkInId = newID()
        try? CheckInRepository(dbWriter).insert(CheckIn(
            id: checkInId, userId: userId, occurredAt: now, timezone: timeZone.identifier,
            rawTranscript: transcript, audioPath: nil, sttEngine: sttEngine,
            inputMethod: inputMethod.rawValue, parseStatus: ParseStatus.pending.rawValue,
            createdAt: now, updatedAt: now, deletedAt: nil
        ))
        return await parseAndReconcile(checkInId: checkInId, transcript: transcript, now: now, timeZone: timeZone, userId: userId)
    }

    /// Re-runs parsing for an existing check-in (a previously failed/manual one).
    /// Times resolve against the check-in's original moment and stored timezone —
    /// never against "now", so re-parsing yesterday's "finished at 7" can't drift.
    /// Check-ins that already produced events are skipped (would duplicate them).
    public func reparse(checkInId: String, userId: String? = nil) async -> CaptureOutcome {
        guard let ci = try? CheckInRepository(dbWriter).find(id: checkInId) else {
            return .failedParse(checkInId: checkInId, error: "check-in not found")
        }
        guard ci.parseStatus != ParseStatus.parsed.rawValue else {
            return .skipped(checkInId: checkInId, reason: "already structured")
        }
        let tz = TimeZone(identifier: ci.timezone) ?? .current
        return await parseAndReconcile(
            checkInId: checkInId, transcript: ci.rawTranscript,
            now: ci.occurredAt, timeZone: tz, userId: userId
        )
    }

    private func parseAndReconcile(checkInId: String, transcript: String, now: Int64, timeZone: TimeZone, userId: String?) async -> CaptureOutcome {
        let checkIns = CheckInRepository(dbWriter)
        guard let parser else {
            try? checkIns.setParseStatus(id: checkInId, .manual, now: now)
            return .manual(checkInId: checkInId)
        }
        let existing = (try? CategoryRepository(dbWriter).live().map(\.name)) ?? []
        do {
            let parsed = try await parser.parse(
                transcript: transcript, now: now, timeZone: timeZone, existingCategories: existing
            )
            recordParseRun(checkInId: checkInId, succeeded: true, output: encode(parsed), error: nil, now: now)
            let result = try TimelineService(dbWriter).reconcile(
                parsed, now: now, timeZone: timeZone, userId: userId, checkInId: checkInId
            )
            try? checkIns.setParseStatus(id: checkInId, .parsed, now: now)
            return .parsed(checkInId: checkInId, batchId: result.batchId)
        } catch {
            recordParseRun(checkInId: checkInId, succeeded: false, output: nil, error: "\(error)", now: now)
            try? checkIns.setParseStatus(id: checkInId, .failed, now: now)
            return .failedParse(checkInId: checkInId, error: "\(error)")
        }
    }

    private func recordParseRun(checkInId: String, succeeded: Bool, output: String?, error: String?, now: Int64) {
        try? ParseRunRepository(dbWriter).insert(ParseRun(
            id: newID(), checkInId: checkInId, parser: "foundation_models", modelId: nil,
            promptVersion: parser?.promptVersion ?? "manual",
            rawOutput: output, succeeded: succeeded, error: error, createdAt: now
        ))
    }

    private func encode(_ parsed: ParsedCheckIn) -> String? {
        (try? JSONEncoder().encode(parsed)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
