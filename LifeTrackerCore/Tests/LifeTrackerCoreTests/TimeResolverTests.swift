import Foundation
import Testing
@testable import LifeTrackerCore

struct TimeResolverTests {
    private let tz = TimeZone(identifier: "UTC")!
    private let dayStart: Int64 = LocalDay(year: 2026, month: 6, day: 16).bounds(in: TimeZone(identifier: "UTC")!).startMs
    private func h(_ hours: Int, _ minutes: Int = 0) -> Int64 { Int64(hours) * 3600_000 + Int64(minutes) * 60_000 }

    @Test func explicit24HourIsUnambiguous() {
        let r = TimeResolver(now: dayStart + h(8), timeZone: tz)
        #expect(r.resolveClock("15:30") == dayStart + h(15, 30))
    }

    @Test func meridiemIsHonored() {
        let r = TimeResolver(now: dayStart + h(8), timeZone: tz)
        #expect(r.resolveClock("5:50pm") == dayStart + h(17, 50))
        #expect(r.resolveClock("7am") == dayStart + h(7))
        #expect(r.resolveClock("12am") == dayStart) // midnight
        #expect(r.resolveClock("12pm") == dayStart + h(12)) // noon
    }

    @Test func futureDirectionPicksUpcomingForPlanning() {
        // Morning planning: "class 3:30" should resolve to 15:30 (next), not 03:30 (past).
        let r = TimeResolver(now: dayStart + h(8), timeZone: tz)
        #expect(r.resolveClock("3:30", direction: .future) == dayStart + h(15, 30))
    }

    @Test func pastDirectionPicksMostRecentForCompleted() {
        // Evening: "finished at 7" should resolve to 19:00, not 07:00.
        let r = TimeResolver(now: dayStart + h(19, 30), timeZone: tz)
        #expect(r.resolveClock("7", direction: .past) == dayStart + h(19))
    }

    @Test func futureWrapsToNextDayWhenAlreadyPast() {
        // Late night: planning "9" with nothing left today → tomorrow 09:00.
        let r = TimeResolver(now: dayStart + h(23), timeZone: tz)
        let tomorrow9 = dayStart + h(24) + h(9)
        #expect(r.resolveClock("9", direction: .future) == tomorrow9)
    }

    @Test func ambiguousHoursPreferWakingHours() {
        // "class at 3" said at 5 PM → tomorrow 3 PM, never 3 AM tomorrow.
        let evening = TimeResolver(now: dayStart + h(17), timeZone: tz)
        #expect(evening.resolveClock("3", direction: .future) == dayStart + h(24) + h(15))
        // Retime to "4" said mid-morning → 4 PM today (nearest waking reading), not 4 AM.
        let morning = TimeResolver(now: dayStart + h(9), timeZone: tz)
        #expect(morning.resolveClock("4", direction: .nearest) == dayStart + h(16))
        // Past stays unbiased: "went to bed at 2" said at 9 AM → 2 AM today.
        #expect(morning.resolveClock("2", direction: .past) == dayStart + h(2))
    }

    @Test func lateNightPlansResolveToSmallHours() {
        // Awake at 11:50 PM planning "at 12" and "at 2" → 12 AM / 2 AM, not noon / 2 PM.
        let lateNight = TimeResolver(now: dayStart + h(23, 50), timeZone: tz)
        #expect(lateNight.resolveClock("12", direction: .future) == dayStart + h(24))
        #expect(lateNight.resolveClock("2", direction: .future) == dayStart + h(26))
        // And just past midnight too.
        let pastMidnight = TimeResolver(now: dayStart + h(24, 30), timeZone: tz)
        #expect(pastMidnight.resolveClock("2", direction: .future) == dayStart + h(26))
        // A recent small-hours reference resolves nearby, not to noon.
        #expect(pastMidnight.resolveClock("12", direction: .nearest) == dayStart + h(24))
    }

    @Test func noonAndMidnight() {
        let r = TimeResolver(now: dayStart + h(10), timeZone: tz)
        #expect(r.resolveClock("noon") == dayStart + h(12))
        #expect(r.resolveClock("midnight", direction: .past) == dayStart)
    }

    @Test func nowIsAStatedTime() {
        // "worked until now" → the model reports statedEnd "now".
        let r = TimeResolver(now: dayStart + h(14), timeZone: tz)
        #expect(r.resolveClock("now", direction: .past) == dayStart + h(14))
        #expect(r.resolveClock("until now") == dayStart + h(14))
        #expect(r.resolveClock("noon") == dayStart + h(12))   // never confused with "now"
    }

    @Test func durations() {
        let r = TimeResolver(now: dayStart, timeZone: tz)
        #expect(r.resolveDuration("2 hours") == h(2))
        #expect(r.resolveDuration("45 minutes") == h(0, 45))
        #expect(r.resolveDuration("1.5 hours") == h(1, 30))
        #expect(r.resolveDuration("1h30m") == h(1, 30))
        #expect(r.resolveDuration("an hour") == h(1))
        #expect(r.resolveDuration("half an hour") == h(0, 30))
        #expect(r.resolveDuration("90 minutes") == h(1, 30))
        #expect(r.resolveDuration("nope") == nil)
    }

    @Test func relativeReferences() {
        let now = dayStart + h(15)
        let r = TimeResolver(now: now, timeZone: tz)
        #expect(r.resolveRelative("an hour ago") == now - h(1))
        #expect(r.resolveRelative("20 minutes ago") == now - h(0, 20))
        #expect(r.resolveRelative("2 hours ago") == now - h(2))
        #expect(r.resolveRelative("just now") == now)
        #expect(r.resolveRelative("since 2pm") == dayStart + h(14))
    }

    @Test func garbageReturnsNil() {
        let r = TimeResolver(now: dayStart, timeZone: tz)
        #expect(r.resolveClock("later") == nil)
        #expect(r.resolveClock("") == nil)
    }
}
