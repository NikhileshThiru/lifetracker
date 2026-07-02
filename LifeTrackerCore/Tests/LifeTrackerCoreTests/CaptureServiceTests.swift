import Foundation
import Testing
import GRDB
@testable import LifeTrackerCore

private struct MockParser: TranscriptParser {
    let result: ParsedCheckIn
    var sawCategories: [String] = []
    func parse(transcript: String, now: Int64, timeZone: TimeZone, existingCategories: [String]) async throws -> ParsedCheckIn {
        result
    }
}

private struct FailingParser: TranscriptParser {
    struct Boom: Error {}
    func parse(transcript: String, now: Int64, timeZone: TimeZone, existingCategories: [String]) async throws -> ParsedCheckIn {
        throw Boom()
    }
}

struct CaptureServiceTests {
    let tz = TimeZone(identifier: "UTC")!

    @Test func ingestWithParserStoresTranscriptParseRunAndEvents() async throws {
        let db = try AppDatabase.makeInMemory()
        let parsed = ParsedCheckIn(blocks: [
            ParsedBlock(title: "gym", category: "workout", categoryKind: "exercise", temporalState: "planned")
        ])
        let svc = CaptureService(dbWriter: db.dbWriter, parser: MockParser(result: parsed))

        let outcome = await svc.ingest(transcript: "going to the gym later", inputMethod: .voice, sttEngine: "mock", timeZone: tz)

        guard case let .parsed(checkInId, _) = outcome else {
            Issue.record("expected .parsed, got \(outcome)"); return
        }
        try await db.dbWriter.read { db in
            let ci = try CheckIn.fetchOne(db, key: checkInId)
            #expect(ci?.rawTranscript == "going to the gym later")  // always stored
            #expect(ci?.parseStatus == ParseStatus.parsed.rawValue)
            let runs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM parse_runs WHERE succeeded = 1")
            #expect(runs == 1)
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE deleted_at IS NULL")
            #expect(events == 1)   // the planned gym block
        }
    }

    @Test func ingestWithoutParserIsManualAndStoresTranscript() async throws {
        let db = try AppDatabase.makeInMemory()
        let svc = CaptureService(dbWriter: db.dbWriter, parser: nil)

        let outcome = await svc.ingest(transcript: "had lunch", inputMethod: .typed, sttEngine: "manual", timeZone: tz)

        guard case let .manual(checkInId) = outcome else {
            Issue.record("expected .manual, got \(outcome)"); return
        }
        try await db.dbWriter.read { db in
            let status = try CheckIn.fetchOne(db, key: checkInId)?.parseStatus
            #expect(status == ParseStatus.manual.rawValue)
            let eventCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events")
            #expect(eventCount == 0)
        }
    }

    @Test func reparseStructuresAPreviouslyManualCheckIn() async throws {
        let db = try AppDatabase.makeInMemory()
        // No parser → saved as manual, no events, shows up as needing attention.
        let manual = await CaptureService(dbWriter: db.dbWriter, parser: nil)
            .ingest(transcript: "going to the gym", inputMethod: .voice, sttEngine: "x", timeZone: tz)
        guard case let .manual(checkInId) = manual else { Issue.record("expected manual"); return }
        let pending = try CheckInRepository(db.dbWriter).needingAttention()
        #expect(pending.contains { $0.id == checkInId })

        // Re-parse with a parser available → structures it.
        let parsed = ParsedCheckIn(blocks: [
            ParsedBlock(title: "gym", category: "workout", categoryKind: "exercise", temporalState: "planned")
        ])
        let outcome = await CaptureService(dbWriter: db.dbWriter, parser: MockParser(result: parsed))
            .reparse(checkInId: checkInId)
        guard case .parsed = outcome else { Issue.record("expected parsed"); return }

        try await db.dbWriter.read { db in
            let status = try CheckIn.fetchOne(db, key: checkInId)?.parseStatus
            #expect(status == ParseStatus.parsed.rawValue)
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE deleted_at IS NULL")
            #expect(events == 1)
        }
        let after = try CheckInRepository(db.dbWriter).needingAttention()
        #expect(!after.contains { $0.id == checkInId })
    }

    @Test func reparseResolvesAgainstOriginalCheckInTime() async throws {
        let db = try AppDatabase.makeInMemory()
        let day = LocalDay(year: 2026, month: 6, day: 16).bounds(in: tz).startMs
        let originalNow = day + 18 * 3_600_000   // said at 6 PM that day

        // Parse fails at capture time; the transcript is preserved.
        let failed = await CaptureService(dbWriter: db.dbWriter, parser: FailingParser())
            .ingest(transcript: "finished work at 5", inputMethod: .voice, sttEngine: "x",
                    now: originalNow, timeZone: tz)
        guard case let .failedParse(checkInId, _) = failed else { Issue.record("expected failed"); return }

        // Re-parsed days later: "5" must still mean 5 PM of the ORIGINAL day.
        let parsed = ParsedCheckIn(blocks: [
            ParsedBlock(title: "work", category: "work", categoryKind: "work",
                        statedEnd: "5", temporalState: "completed")
        ])
        let outcome = await CaptureService(dbWriter: db.dbWriter, parser: MockParser(result: parsed))
            .reparse(checkInId: checkInId)
        guard case .parsed = outcome else { Issue.record("expected parsed"); return }

        let end = try await db.dbWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT end_at FROM events WHERE title = 'work'")
        }
        #expect(end == day + 17 * 3_600_000)
    }

    @Test func reparseOfAlreadyParsedCheckInIsSkipped() async throws {
        let db = try AppDatabase.makeInMemory()
        let parsed = ParsedCheckIn(blocks: [
            ParsedBlock(title: "gym", category: "workout", categoryKind: "exercise", temporalState: "planned")
        ])
        let svc = CaptureService(dbWriter: db.dbWriter, parser: MockParser(result: parsed))
        let first = await svc.ingest(transcript: "gym later", inputMethod: .voice, sttEngine: "x", timeZone: tz)
        guard case let .parsed(checkInId, _) = first else { Issue.record("expected parsed"); return }

        let again = await svc.reparse(checkInId: checkInId)
        guard case .skipped = again else { Issue.record("expected skipped, got \(again)"); return }
        let events = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE deleted_at IS NULL")
        }
        #expect(events == 1)   // no duplicates
    }

    @Test func ingestParserFailureKeepsTranscriptAndMarksFailed() async throws {
        let db = try AppDatabase.makeInMemory()
        let svc = CaptureService(dbWriter: db.dbWriter, parser: FailingParser())

        let outcome = await svc.ingest(transcript: "mumble mumble", inputMethod: .voice, sttEngine: "mock", timeZone: tz)

        guard case let .failedParse(checkInId, _) = outcome else {
            Issue.record("expected .failedParse, got \(outcome)"); return
        }
        try await db.dbWriter.read { db in
            let ci = try CheckIn.fetchOne(db, key: checkInId)
            #expect(ci?.rawTranscript == "mumble mumble")  // preserved for re-parse
            #expect(ci?.parseStatus == ParseStatus.failed.rawValue)
            let failRuns = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM parse_runs WHERE succeeded = 0")
            #expect(failRuns == 1)
        }
    }
}
