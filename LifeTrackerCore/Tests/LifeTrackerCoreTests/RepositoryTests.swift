import Foundation
import Testing
import GRDB
@testable import LifeTrackerCore

struct RepositoryTests {
    // Builds a fresh in-memory DB and the repos under test.
    private func fixture() throws -> (AppDatabase, EventRepository, CategoryRepository, CheckInRepository) {
        let db = try AppDatabase.makeInMemory()
        return (db, EventRepository(db.dbWriter), CategoryRepository(db.dbWriter), CheckInRepository(db.dbWriter))
    }

    private func makeEvent(
        id: String = newID(), start: Int64?, end: Int64?, state: EventState,
        source: EventSource = .voice, sourceRef: String? = nil, seq: Int? = nil,
        now: Int64
    ) -> Event {
        Event(
            id: id, userId: "u1", categoryId: nil, title: "t", notes: nil,
            startAt: start, endAt: end, state: state.rawValue, sequenceHint: seq,
            confidence: 1.0, source: source.rawValue, sourceRef: sourceRef,
            originCheckInId: nil, isPinned: false, createdAt: now, updatedAt: now, deletedAt: nil
        )
    }

    @Test func softDeleteHidesFromLiveButKeepsTombstone() throws {
        let (_, _, cats, _) = try fixture()
        let now = Clock.nowMillis()
        let c = Category(
            id: newID(), userId: "u1", parentId: nil, name: "Swimming",
            kind: "exercise", colorHex: nil, icon: nil, isDefault: false,
            createdBy: "auto", sortOrder: 1, isArchived: false,
            createdAt: now, updatedAt: now, deletedAt: nil
        )
        try cats.insert(c)
        let beforeLive = try cats.live().count       // 9 seeded defaults + 1
        try cats.softDelete(id: c.id)

        #expect(try cats.live().count == beforeLive - 1)
        #expect(try cats.find(id: c.id)?.deletedAt != nil) // tombstone survives
    }

    @Test func updateBumpsUpdatedAt() throws {
        let (_, events, _, _) = try fixture()
        let t0: Int64 = 1_000_000
        var e = makeEvent(start: t0, end: nil, state: .confirmed, now: t0)
        try events.insert(e)
        e.title = "renamed"
        try events.update(e, now: t0 + 5_000)
        let fetched = try events.find(id: e.id)
        #expect(fetched?.title == "renamed")
        #expect(fetched?.updatedAt == t0 + 5_000)
    }

    @Test func openBlockIsConfirmedWithNoEnd() throws {
        let (_, events, _, _) = try fixture()
        let now = Clock.nowMillis()
        let open = makeEvent(start: now - 3600_000, end: nil, state: .confirmed, now: now)
        let loosePlanned = makeEvent(start: nil, end: nil, state: .planned, seq: 0, now: now)
        let closed = makeEvent(start: now - 7200_000, end: now - 3600_000, state: .confirmed, now: now)
        try events.insert(open)
        try events.insert(loosePlanned)
        try events.insert(closed)

        let found = try events.openBlock(userId: "u1")
        #expect(found?.id == open.id)
    }

    @Test func plannedBlocksOrderedBySequence() throws {
        let (_, events, _, _) = try fixture()
        let now = Clock.nowMillis()
        try events.insert(makeEvent(id: "b", start: nil, end: nil, state: .planned, seq: 2, now: now))
        try events.insert(makeEvent(id: "a", start: nil, end: nil, state: .planned, seq: 1, now: now))
        try events.insert(makeEvent(id: "c", start: nil, end: nil, state: .planned, seq: 3, now: now))
        let ids = try events.plannedBlocks(userId: "u1").map(\.id)
        #expect(ids == ["a", "b", "c"])
    }

    @Test func eventsOnDayUsesOverlapWindow() throws {
        let (_, events, _, _) = try fixture()
        let tz = TimeZone(identifier: "UTC")!
        let day = LocalDay(year: 2026, month: 6, day: 16)
        let (start, end) = day.bounds(in: tz)
        let now = start

        let inside = makeEvent(start: start + 9 * 3600_000, end: start + 10 * 3600_000, state: .confirmed, now: now)
        let openLate = makeEvent(start: start + 23 * 3600_000, end: nil, state: .confirmed, now: now)
        let prevDay = makeEvent(start: start - 5 * 3600_000, end: start - 4 * 3600_000, state: .confirmed, now: now)
        let nextDay = makeEvent(start: end + 3600_000, end: end + 2 * 3600_000, state: .confirmed, now: now)
        let loose = makeEvent(start: nil, end: nil, state: .planned, now: now)
        for e in [inside, openLate, prevDay, nextDay, loose] { try events.insert(e) }

        let ids = Set(try events.events(on: day, tz: tz, userId: "u1").map(\.id))
        #expect(ids == [inside.id, openLate.id])
    }

    @Test func upsertBySourceRefIsIdempotent() throws {
        let (db, events, _, _) = try fixture()
        let now = Clock.nowMillis()
        let first = makeEvent(start: now, end: now + 3600_000, state: .confirmed, source: .healthkit, sourceRef: "hk-1", now: now)
        let dup = makeEvent(start: now, end: now + 3600_000, state: .confirmed, source: .healthkit, sourceRef: "hk-1", now: now)

        let a = try events.upsertBySourceRef(first)
        let b = try events.upsertBySourceRef(dup)
        #expect(a.id == b.id) // second call returns the existing row

        let count = try db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE source='healthkit' AND source_ref='hk-1'")
        }
        #expect(count == 1)
    }

    @Test func setParseStatusUpdates() throws {
        let (_, _, _, checkIns) = try fixture()
        let now = Clock.nowMillis()
        let ci = CheckIn(
            id: newID(), userId: "u1", occurredAt: now, timezone: "UTC",
            rawTranscript: "went for a run", audioPath: nil, sttEngine: "test",
            inputMethod: InputMethod.voice.rawValue, parseStatus: ParseStatus.pending.rawValue,
            createdAt: now, updatedAt: now, deletedAt: nil
        )
        try checkIns.insert(ci)
        try checkIns.setParseStatus(id: ci.id, .parsed)
        #expect(try checkIns.find(id: ci.id)?.parseStatus == ParseStatus.parsed.rawValue)
    }
}
