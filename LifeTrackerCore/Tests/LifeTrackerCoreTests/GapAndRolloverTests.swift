import Foundation
import Testing
import GRDB
@testable import LifeTrackerCore

struct GapCalculatorTests {
    let tz = TimeZone(identifier: "UTC")!
    let day = LocalDay(year: 2026, month: 6, day: 16)
    var base: Int64 { day.bounds(in: tz).startMs }
    func h(_ hr: Int, _ m: Int = 0) -> Int64 { Int64(hr) * 3600_000 + Int64(m) * 60_000 }

    private func confirmed(start: Int64, end: Int64?) -> Event {
        Event(id: newID(), userId: "u1", categoryId: nil, title: "x", notes: nil,
              startAt: start, endAt: end, state: EventState.confirmed.rawValue, sequenceHint: nil,
              confidence: 1.0, source: EventSource.voice.rawValue, sourceRef: nil,
              originCheckInId: nil, isPinned: false, createdAt: start, updatedAt: start, deletedAt: nil)
    }

    @Test func pastDaySplitsIntoOvernightAndDaytimeGaps() {
        let events = [confirmed(start: base + h(9), end: base + h(17))]
        let gaps = GapCalculator.gaps(events: events, day: day, timeZone: tz, now: base + h(48))
        #expect(gaps.count == 2)
        #expect(gaps[0].kind == .sleepCandidate)   // 00:00–09:00
        #expect(gaps[0].minutes == 9 * 60)
        #expect(gaps[1].kind == .todo)             // 17:00–24:00
    }

    @Test func subFifteenMinuteGapsAreAbsorbed() {
        let events = [
            confirmed(start: base + h(9), end: base + h(10)),
            confirmed(start: base + h(10, 10), end: base + h(17)), // 10-min gap before this
        ]
        let gaps = GapCalculator.gaps(events: events, day: day, timeZone: tz, now: base + h(48))
        // Only the overnight + evening gaps; the 10-minute one is absorbed.
        #expect(gaps.allSatisfy { $0.minutes >= GapCalculator.minGapMinutes })
        #expect(!gaps.contains { $0.startAt == base + h(10) })
    }

    @Test func todayDoesNotTreatFutureAsGap() {
        let events = [confirmed(start: base + h(9), end: base + h(10))]
        let gaps = GapCalculator.gaps(events: events, day: day, timeZone: tz, now: base + h(12))
        // overnight [0,9) + [10,12); nothing past noon.
        #expect(gaps.last?.endAt == base + h(12))
        #expect(!gaps.contains { $0.startAt >= base + h(12) })
    }

    @Test func futureDayHasNoGaps() {
        let gaps = GapCalculator.gaps(events: [], day: day, timeZone: tz, now: base - h(24))
        #expect(gaps.isEmpty)
    }

    @Test func openBlockExtendsToNow() {
        let events = [confirmed(start: base + h(9), end: nil)] // in progress
        let gaps = GapCalculator.gaps(events: events, day: day, timeZone: tz, now: base + h(12))
        // Covered 09:00→12:00(now); only overnight gap remains.
        #expect(gaps.count == 1)
        #expect(gaps[0].kind == .sleepCandidate)
        #expect(gaps[0].endAt == base + h(9))
    }

    @Test func coveredMinutesIsAUnionNeverDoubleCounted() {
        // Two blocks overlapping 10:00–12:00: union is 9:00–13:00 = 4h, not 6h.
        let events = [
            confirmed(start: base + h(9), end: base + h(12)),
            confirmed(start: base + h(10), end: base + h(13)),
        ]
        let mins = GapCalculator.coveredMinutes(events: events, day: day, timeZone: tz, now: base + h(20))
        #expect(mins == 4 * 60)
        // And it can never exceed the day, whatever the data claims.
        let monster = [confirmed(start: base - h(20), end: base + h(40))]
        #expect(GapCalculator.coveredMinutes(events: monster, day: day, timeZone: tz, now: base + h(48)) <= 24 * 60)
    }
}

struct RolloverTests {
    let tz = TimeZone(identifier: "UTC")!
    let day = LocalDay(year: 2026, month: 6, day: 16)
    var base: Int64 { day.bounds(in: tz).startMs }
    func h(_ hr: Int, _ m: Int = 0) -> Int64 { Int64(hr) * 3600_000 + Int64(m) * 60_000 }

    private func planned(start: Int64?, createdAt: Int64) -> Event {
        Event(id: newID(), userId: "u1", categoryId: nil, title: "p", notes: nil,
              startAt: start, endAt: nil, state: EventState.planned.rawValue, sequenceHint: start == nil ? 1 : nil,
              confidence: 0.6, source: EventSource.voice.rawValue, sourceRef: nil,
              originCheckInId: nil, isPinned: false, createdAt: createdAt, updatedAt: createdAt, deletedAt: nil)
    }

    @Test func expiresOnlyStalePlanned() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = EventRepository(db.dbWriter)
        let svc = TimelineService(db.dbWriter)

        let yesterdayPinned = planned(start: base - h(14), createdAt: base - h(20))   // stale
        let todayPinned = planned(start: base + h(15), createdAt: base + h(1))         // fresh
        let yesterdayLoose = planned(start: nil, createdAt: base - h(5))               // stale
        let todayLoose = planned(start: nil, createdAt: base + h(1))                   // fresh
        for e in [yesterdayPinned, todayPinned, yesterdayLoose, todayLoose] { try repo.insert(e) }

        let expired = try svc.expireStalePlanned(asOf: base + h(2), timeZone: tz, userId: "u1")
        #expect(Set(expired) == Set([yesterdayPinned.id, yesterdayLoose.id]))

        let alive = Set(try repo.plannedBlocks(userId: "u1").map(\.id))
        #expect(alive == Set([todayPinned.id, todayLoose.id]))
    }

    private func open(start: Int64, categoryId: String? = nil) -> Event {
        Event(id: newID(), userId: "u1", categoryId: categoryId, title: "o", notes: nil,
              startAt: start, endAt: nil, state: EventState.confirmed.rawValue, sequenceHint: nil,
              confidence: 1.0, source: EventSource.voice.rawValue, sourceRef: nil,
              originCheckInId: nil, isPinned: false, createdAt: start, updatedAt: start, deletedAt: nil)
    }

    @Test func closesOpenBlocksLeftRunningOnAPreviousDay() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = EventRepository(db.dbWriter)
        let svc = TimelineService(db.dbWriter)

        let staleOpen = open(start: base - h(10))      // yesterday 14:00, still "in progress"
        let todayOpen = open(start: base + h(9))       // today, genuinely in progress
        try repo.insert(staleOpen)
        try repo.insert(todayOpen)

        let closed = try svc.closeStaleOpenBlocks(asOf: base + h(10), timeZone: tz, userId: "u1")
        #expect(closed == [staleOpen.id])

        let fixed = try #require(try repo.find(id: staleOpen.id))
        #expect(fixed.endAt == base - h(9))            // modest 1h default, its own day
        #expect(fixed.confidence < 1.0)
        let untouched = try #require(try repo.find(id: todayOpen.id))
        #expect(untouched.endAt == nil)
    }

    @Test func staleOpenSleepFromLastNightIsSpared() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = EventRepository(db.dbWriter)
        let svc = TimelineService(db.dbWriter)
        let sleepCat = try #require(try CategoryRepository(db.dbWriter).live().first { $0.kind == "sleep" })

        let sleeping = open(start: base - h(1), categoryId: sleepCat.id)   // bed at 23:00
        try repo.insert(sleeping)

        // 7 AM: sleep is only 8h old — the wake-up anchor owns it, not maintenance.
        let closed = try svc.closeStaleOpenBlocks(asOf: base + h(7), timeZone: tz, userId: "u1")
        #expect(closed.isEmpty)
        #expect(try #require(try repo.find(id: sleeping.id)).endAt == nil)
    }
}
