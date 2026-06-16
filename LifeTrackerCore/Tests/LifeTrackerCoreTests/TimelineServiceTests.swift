import Foundation
import Testing
import GRDB
@testable import LifeTrackerCore

struct TimelineServiceTests {
    let tz = TimeZone(identifier: "UTC")!
    let base = LocalDay(year: 2026, month: 6, day: 16).bounds(in: TimeZone(identifier: "UTC")!).startMs
    func h(_ hr: Int, _ m: Int = 0) -> Int64 { Int64(hr) * 3600_000 + Int64(m) * 60_000 }

    private func env() throws -> (AppDatabase, TimelineService) {
        let db = try AppDatabase.makeInMemory()
        return (db, TimelineService(db.dbWriter))
    }

    private func find(_ db: AppDatabase, title: String) throws -> Event? {
        try db.dbWriter.read {
            try Event.filter(Column("title") == title).order(Column("created_at").desc).fetchOne($0)
        }
    }

    private func categoryId(_ db: AppDatabase, name: String) throws -> String {
        try db.dbWriter.read { try Category.filter(Column("name") == name).fetchOne($0)!.id }
    }

    private func planned(_ title: String, _ category: String, _ kind: String, start: String? = nil, end: String? = nil) -> ParsedBlock {
        ParsedBlock(title: title, category: category, categoryKind: kind, statedStart: start, statedEnd: end, temporalState: "planned")
    }

    // MARK: - Spec §5 scenarios

    @Test func planningCreatesFixedAndLooseBlocks() throws {
        let (db, svc) = try env()
        let now = base + h(8) // morning planning
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                planned("class", "Work", "work", start: "3:30", end: "5:30"),
                planned("workout", "workout", "exercise"), // no times → loose
            ]),
            now: now, timeZone: tz, userId: "u1"
        )

        let cls = try #require(try find(db, title: "class"))
        #expect(cls.state == EventState.planned.rawValue)
        #expect(cls.startAt == base + h(15, 30))
        #expect(cls.endAt == base + h(17, 30))

        let workout = try #require(try find(db, title: "workout"))
        #expect(workout.startAt == nil)            // loose
        #expect(workout.sequenceHint != nil)       // ordered placeholder
    }

    @Test func finishingRetimesPlannedBlock() throws {
        let (db, svc) = try env()
        try svc.reconcile(ParsedCheckIn(blocks: [planned("class", "Work", "work", start: "3:30", end: "5:30")]),
                          now: base + h(8), timeZone: tz, userId: "u1")
        // "Just finished class, ran late, ended at 5:50."
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "class", category: "Work", categoryKind: "work",
                            statedEnd: "5:50", temporalState: "completed")
            ]),
            now: base + h(17, 55), timeZone: tz, userId: "u1"
        )
        let cls = try #require(try find(db, title: "class"))
        #expect(cls.state == EventState.confirmed.rawValue)
        #expect(cls.endAt == base + h(17, 50))
        #expect(cls.startAt == base + h(15, 30)) // start preserved
    }

    @Test func doneWithOpenBlockClosesItAndOpensNext() throws {
        let (db, svc) = try env()
        // Earlier: workout in progress from 5pm.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "workout", category: "workout", categoryKind: "exercise",
                                               statedStart: "5pm", temporalState: "inProgress")]),
            now: base + h(17), timeZone: tz, userId: "u1"
        )
        // "Done with the workout, finished at 7, now dinner."
        let result = try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "workout", category: "workout", categoryKind: "exercise",
                            statedEnd: "7", temporalState: "completed", closesOpenBlock: true),
                ParsedBlock(title: "dinner", category: "dinner", categoryKind: "meal",
                            temporalState: "inProgress"),
            ]),
            now: base + h(19, 30), timeZone: tz, userId: "u1"
        )

        let workout = try #require(try find(db, title: "workout"))
        #expect(workout.state == EventState.confirmed.rawValue)
        #expect(workout.endAt == base + h(19))   // "7" → 19:00 (past direction)

        let dinner = try #require(try find(db, title: "dinner"))
        #expect(dinner.endAt == nil)             // now the open block
        #expect(dinner.startAt == base + h(19, 30))

        // Undo unit: one batch grouping both changes.
        #expect(result.affectedEventIds.count == 2)
        let revs = try RevisionRepository(db.dbWriter).byBatch(result.batchId)
        #expect(Set(revs.map(\.eventId)) == Set(result.affectedEventIds))
    }

    @Test func multiplePlannedWithoutTimesKeepOrder() throws {
        let (db, svc) = try env()
        try svc.reconcile(ParsedCheckIn(blocks: [
            planned("class", "Work", "work"),
            planned("run", "run", "exercise"),
            planned("eat", "eat", "meal"),
        ]), now: base + h(9), timeZone: tz, userId: "u1")

        let order = try EventRepository(db.dbWriter).plannedBlocks(userId: "u1").map(\.title)
        #expect(order == ["class", "run", "eat"])
    }

    @Test func skipDeletesPlannedBlock() throws {
        let (db, svc) = try env()
        try svc.reconcile(ParsedCheckIn(blocks: [planned("run", "run", "exercise")]),
                          now: base + h(9), timeZone: tz, userId: "u1")
        try svc.reconcile(ParsedCheckIn(anchors: [ParsedAnchor(kind: "skip", targetHint: "run")]),
                          now: base + h(12), timeZone: tz, userId: "u1")

        let run = try #require(try find(db, title: "run"))
        #expect(run.deletedAt != nil)
        #expect(try EventRepository(db.dbWriter).plannedBlocks(userId: "u1").isEmpty)
    }

    @Test func skipOfNonexistentIsNoOp() throws {
        let (db, svc) = try env()
        let result = try svc.reconcile(
            ParsedCheckIn(anchors: [ParsedAnchor(kind: "skip", targetHint: "run")]),
            now: base + h(12), timeZone: tz, userId: "u1"
        )
        #expect(result.affectedEventIds.isEmpty)
        let count = try db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM events") }
        #expect(count == 0)
    }

    @Test func retimeAnchorCarriesStartAndEnd() throws {
        let (db, svc) = try env()
        try svc.reconcile(ParsedCheckIn(blocks: [planned("class", "Work", "work", start: "3:30", end: "5:30")]),
                          now: base + h(8), timeZone: tz, userId: "u1")
        // "Actually class was 4 to 6, not 3:30." (said early afternoon)
        try svc.reconcile(
            ParsedCheckIn(anchors: [ParsedAnchor(kind: "retime", targetHint: "class", newStart: "4", newEnd: "6")]),
            now: base + h(14), timeZone: tz, userId: "u1"
        )
        let cls = try #require(try find(db, title: "class"))
        #expect(cls.startAt == base + h(16))
        #expect(cls.endAt == base + h(18))
    }

    @Test func wakeUpClosesOpenSleepBlock() throws {
        let (db, svc) = try env()
        let sleepCat = try categoryId(db, name: "Sleep")
        let bedtime = base - h(1) // 11pm previous day
        try EventRepository(db.dbWriter).insert(Event(
            id: newID(), userId: "u1", categoryId: sleepCat, title: "sleep", notes: nil,
            startAt: bedtime, endAt: nil, state: EventState.confirmed.rawValue, sequenceHint: nil,
            confidence: 1.0, source: EventSource.voice.rawValue, sourceRef: nil,
            originCheckInId: nil, isPinned: false, createdAt: bedtime, updatedAt: bedtime, deletedAt: nil
        ))
        // "Just woke up — about an hour ago." now 7am.
        try svc.reconcile(
            ParsedCheckIn(anchors: [ParsedAnchor(kind: "wakeUp", relativeReference: "an hour ago")]),
            now: base + h(7), timeZone: tz, userId: "u1"
        )
        let sleep = try #require(try find(db, title: "sleep"))
        #expect(sleep.endAt == base + h(6))
        #expect(sleep.state == EventState.confirmed.rawValue)
    }

    @Test func backfillSetsStartFromSince() throws {
        let (db, svc) = try env()
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "work", category: "Work", categoryKind: "work",
                                               statedStart: "3pm", temporalState: "inProgress")]),
            now: base + h(15), timeZone: tz, userId: "u1"
        )
        // "Actually I've been working since 2pm."
        try svc.reconcile(
            ParsedCheckIn(anchors: [ParsedAnchor(kind: "backfillStart", targetHint: "work", relativeReference: "since 2pm")]),
            now: base + h(15), timeZone: tz, userId: "u1"
        )
        let work = try #require(try find(db, title: "work"))
        #expect(work.startAt == base + h(14))
    }

    @Test func autoCreatesCategoryForNovelActivity() throws {
        let (db, svc) = try env()
        try svc.reconcile(ParsedCheckIn(blocks: [planned("pickleball", "pickleball", "exercise")]),
                          now: base + h(9), timeZone: tz, userId: "u1")
        let cat = try db.dbWriter.read {
            try Category.filter(Column("name") == "pickleball").fetchOne($0)
        }
        #expect(cat?.createdBy == "auto")
    }
}
