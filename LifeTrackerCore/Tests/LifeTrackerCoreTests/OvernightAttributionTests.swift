import Foundation
import Testing
import GRDB
@testable import LifeTrackerCore

/// An event that crosses midnight (7 PM → 6 AM) must be attributed per local day:
/// each day counts only its own slice, and the display can flag that it spills over.
struct OvernightAttributionTests {
    private let tz = TimeZone(identifier: "America/New_York")!
    private let day1 = LocalDay(year: 2026, month: 6, day: 30) // "yesterday"
    private let day2 = LocalDay(year: 2026, month: 7, day: 1)  // "today"

    private func overnightWork() -> (Event, Int64, Int64, Int64, Int64) {
        let (d1Start, d1End) = day1.bounds(in: tz)   // d1End == d2Start (midnight)
        let (d2Start, d2End) = day2.bounds(in: tz)
        let start = d1Start + 19 * 3_600_000         // 7:00 PM day1
        let end = d2Start + 6 * 3_600_000            // 6:00 AM day2
        let e = Event(
            id: "w", userId: "u1", categoryId: nil, title: "Work", notes: nil,
            startAt: start, endAt: end, state: EventState.confirmed.rawValue, sequenceHint: nil,
            confidence: 1.0, source: EventSource.voice.rawValue, sourceRef: nil,
            originCheckInId: nil, isPinned: false, createdAt: start, updatedAt: start, deletedAt: nil
        )
        return (e, d1Start, d1End, d2Start, d2End)
    }

    @Test func minutesSplitPerDayNotDoubleCounted() {
        let (e, d1Start, d1End, d2Start, d2End) = overnightWork()
        let now = d2End
        // Day 1 gets 7PM→midnight = 5h; day 2 gets midnight→6AM = 6h. Total = the full 11h.
        #expect(e.minutes(in: d1Start, d1End, now: now) == 5 * 60)
        #expect(e.minutes(in: d2Start, d2End, now: now) == 6 * 60)
        #expect(e.minutes(in: d1Start, d1End, now: now) + e.minutes(in: d2Start, d2End, now: now) == 11 * 60)
    }

    @Test func clipReturnsPerDaySlices() {
        let (e, d1Start, d1End, d2Start, d2End) = overnightWork()
        let now = d2End
        let s1 = e.clip(to: d1Start, d1End, now: now)
        let s2 = e.clip(to: d2Start, d2End, now: now)
        #expect(s1?.start == e.startAt)   // day1 slice starts at real start (7PM)
        #expect(s1?.end == d1End)         // clipped to midnight
        #expect(s2?.start == d2Start)     // day2 slice starts at midnight
        #expect(s2?.end == e.endAt)       // ends at real end (6AM)
    }

    @Test func continuationFlags() {
        let (e, d1Start, d1End, d2Start, d2End) = overnightWork()
        let now = d2End
        // Day 1: doesn't start before its own window, but continues after (into day 2).
        #expect(e.continuesBefore(d1Start) == false)
        #expect(e.continuesAfter(d1End, now: now) == true)
        // Day 2: started before this window (yesterday), doesn't continue after.
        #expect(e.continuesBefore(d2Start) == true)
        #expect(e.continuesAfter(d2End, now: now) == false)
    }

    @Test func openBlockClipsAtNow() {
        let (_, d1Start, d1End, d2Start, _) = overnightWork()
        let start = d1Start + 22 * 3_600_000     // 10 PM day1, still open
        let now = d2Start + 2 * 3_600_000        // 2 AM day2
        let open = Event(
            id: "o", userId: "u1", categoryId: nil, title: "Up late", notes: nil,
            startAt: start, endAt: nil, state: EventState.confirmed.rawValue, sequenceHint: nil,
            confidence: 1.0, source: EventSource.voice.rawValue, sourceRef: nil,
            originCheckInId: nil, isPinned: false, createdAt: start, updatedAt: start, deletedAt: nil
        )
        #expect(open.minutes(in: d1Start, d1End, now: now) == 2 * 60)   // 10PM→midnight
        #expect(open.minutes(in: d2Start, now + 3_600_000, now: now) == 2 * 60) // midnight→now(2AM)
    }

    @Test func confirmedOverlappingCatchesSpilloverFromPriorDay() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = EventRepository(db.dbWriter)
        let (e, _, _, d2Start, d2End) = overnightWork()
        try repo.insert(e)

        // Start-based query misses the overnight block on day 2 (it started on day 1)...
        let byStart = try repo.confirmed(in: d2Start..<d2End, userId: "u1").map(\.id)
        #expect(byStart.isEmpty)
        // ...but the overlap query catches it, so day 2 can attribute its slice.
        let overlap = try repo.confirmedOverlapping(in: d2Start..<d2End, userId: "u1").map(\.id)
        #expect(overlap == ["w"])
    }
}
