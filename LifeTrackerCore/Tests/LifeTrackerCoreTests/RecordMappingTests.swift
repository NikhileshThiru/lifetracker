import Foundation
import Testing
import GRDB
@testable import LifeTrackerCore

/// Validates that camelCase Swift properties round-trip through snake_case columns.
struct RecordMappingTests {
    @Test func categoryRoundTripsThroughSnakeCaseColumns() throws {
        let appDB = try AppDatabase.makeInMemory()
        let now = Clock.nowMillis()
        let cat = Category(
            id: newID(), userId: "u1", parentId: nil, name: "Swimming",
            kind: CategoryKind.exercise.rawValue, colorHex: "#30D158", icon: "figure.pool.swim",
            isDefault: false, createdBy: "auto", sortOrder: 42, isArchived: false,
            createdAt: now, updatedAt: now, deletedAt: nil
        )
        try appDB.dbWriter.write { try cat.insert($0) }

        try appDB.dbWriter.read { db in
            // Decodes back into the camelCase struct.
            let fetched = try Category.fetchOne(db, key: cat.id)
            #expect(fetched == cat)

            // Encoded into the actual snake_case columns.
            let row = try Row.fetchOne(db, sql: "SELECT * FROM categories WHERE id = ?", arguments: [cat.id])!
            #expect(row["is_default"] == false)
            #expect(row["color_hex"] == "#30D158")
            #expect(row["sort_order"] == 42)
            #expect(row["created_by"] == "auto")
        }
    }

    @Test func eventRoundTripsWithNullableTimes() throws {
        let appDB = try AppDatabase.makeInMemory()
        let now = Clock.nowMillis()
        let ev = Event(
            id: newID(), userId: "u1", categoryId: nil, title: "run", notes: nil,
            startAt: nil, endAt: nil, state: EventState.planned.rawValue,
            sequenceHint: 3, confidence: 0.5, source: EventSource.voice.rawValue,
            sourceRef: nil, originCheckInId: "c1", isPinned: false,
            createdAt: now, updatedAt: now, deletedAt: nil
        )
        try appDB.dbWriter.write { try ev.insert($0) }
        try appDB.dbWriter.read { db in
            let fetched = try Event.fetchOne(db, key: ev.id)
            #expect(fetched == ev)
            let row = try Row.fetchOne(db, sql: "SELECT * FROM events WHERE id = ?", arguments: [ev.id])!
            #expect(row["start_at"] == nil)
            #expect(row["sequence_hint"] == 3)
            #expect(row["origin_check_in_id"] == "c1")
        }
    }
}

struct LocalDayTests {
    private func tz(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

    @Test func normalDayIs24Hours() {
        let day = LocalDay(year: 2026, month: 6, day: 16)
        let (start, end) = day.bounds(in: tz("America/New_York"))
        #expect(end - start == 24 * 3600 * 1000)
    }

    @Test func springForwardDayIs23Hours() {
        // US DST begins 2026-03-08 (clocks jump 02:00→03:00).
        let day = LocalDay(year: 2026, month: 3, day: 8)
        let (start, end) = day.bounds(in: tz("America/New_York"))
        #expect(end - start == 23 * 3600 * 1000)
    }

    @Test func fallBackDayIs25Hours() {
        // US DST ends 2026-11-01 (clocks fall 02:00→01:00).
        let day = LocalDay(year: 2026, month: 11, day: 1)
        let (start, end) = day.bounds(in: tz("America/New_York"))
        #expect(end - start == 25 * 3600 * 1000)
    }

    @Test func containingRoundTrips() {
        let z = tz("America/Los_Angeles")
        let day = LocalDay(year: 2026, month: 6, day: 16)
        let (start, _) = day.bounds(in: z)
        let mid = Clock.date(fromMillis: start + 12 * 3600 * 1000)
        #expect(LocalDay(containing: mid, in: z) == day)
    }
}
