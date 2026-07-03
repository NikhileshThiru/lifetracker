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
        #expect(dinner.startAt == base + h(19))  // spec §5: opens where workout closed

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

    // MARK: - Multi-activity chains (the core "several things since I last checked in" case)

    @Test func multipleCompletedBlocksChainCompactly() throws {
        let (db, svc) = try env()
        // "Had breakfast at 8, then went to the gym, then showered." said at 11.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "breakfast", category: "breakfast", categoryKind: "meal",
                            statedStart: "8", temporalState: "completed"),
                ParsedBlock(title: "gym", category: "gym", categoryKind: "exercise",
                            temporalState: "completed"),
                ParsedBlock(title: "shower", category: "shower", categoryKind: "chore",
                            temporalState: "completed"),
            ]),
            now: base + h(11), timeZone: tz, userId: "u1"
        )
        let breakfast = try #require(try find(db, title: "breakfast"))
        let gym = try #require(try find(db, title: "gym"))
        let shower = try #require(try find(db, title: "shower"))
        // Stated time honored; untimed blocks get modest defaults walking back
        // from now — the unclaimed mid-morning stays an honest gap.
        #expect(breakfast.startAt == base + h(8))
        #expect(breakfast.endAt == base + h(8, 30))
        #expect(gym.startAt == base + h(10))
        #expect(gym.endAt == base + h(10, 30))
        #expect(shower.startAt == base + h(10, 30))
        #expect(shower.endAt == base + h(11))
        // Inferred boundaries are marked lower-confidence for the UI.
        #expect(gym.confidence < 1.0)
    }

    @Test func chainUsesStatedDurations() throws {
        let (db, svc) = try env()
        // "Worked from 2 for three hours" said at 6 → 14:00–17:00, not 14:00–18:00.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "work", category: "Work", categoryKind: "work",
                            statedStart: "2", statedDuration: "3 hours",
                            temporalState: "completed")
            ]),
            now: base + h(18), timeZone: tz, userId: "u1"
        )
        let work = try #require(try find(db, title: "work"))
        #expect(work.startAt == base + h(14))
        #expect(work.endAt == base + h(17))
    }

    @Test func completedDoesNotStealMismatchedOpenBlock() throws {
        let (db, svc) = try env()
        // "Starting class" at 12:30 → open block.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "class", category: "class", categoryKind: "work",
                                               statedStart: "12:30pm", temporalState: "inProgress")]),
            now: base + h(12, 30), timeZone: tz, userId: "u1"
        )
        // "Just finished lunch." at 14:00 — class must NOT be hijacked; lunch must exist.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "lunch", category: "lunch", categoryKind: "meal",
                                               temporalState: "completed", closesOpenBlock: true)]),
            now: base + h(14), timeZone: tz, userId: "u1"
        )
        let cls = try #require(try find(db, title: "class"))
        let lunch = try #require(try find(db, title: "lunch"))
        #expect(lunch.startAt == base + h(13, 30))   // compact default before now
        #expect(lunch.endAt == base + h(14))
        #expect(cls.endAt == lunch.startAt)          // class hands off to lunch
        #expect(cls.title == "class")                // identity preserved
        #expect(cls.endAt! > cls.startAt!)
    }

    @Test func untimedChainIsCompactBeforeNow() throws {
        let (db, svc) = try env()
        // "Grabbed coffee, then read." at 13:00 → two modest blocks ending at now.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "coffee", category: "coffee", categoryKind: "leisure", temporalState: "completed"),
                ParsedBlock(title: "read", category: "reading", categoryKind: "leisure", temporalState: "completed"),
            ]),
            now: base + h(13), timeZone: tz, userId: "u1"
        )
        let coffee = try #require(try find(db, title: "coffee"))
        let read = try #require(try find(db, title: "read"))
        #expect(coffee.startAt == base + h(12))
        #expect(coffee.endAt == base + h(12, 30))
        #expect(read.startAt == base + h(12, 30))
        #expect(read.endAt == base + h(13))
    }

    @Test func untimedChainNeverReachesAPreviousDay() throws {
        let (db, svc) = try env()
        // The last logged block ended YESTERDAY 23:00.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "movie", category: "movie", categoryKind: "leisure",
                                               statedStart: "10pm", statedEnd: "11pm", temporalState: "completed")]),
            now: base - h(1), timeZone: tz, userId: "u1"
        )
        // Today at 14:00: three untimed activities. They must land compactly
        // this afternoon — NOT stretch back across midnight to 23:00.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "laundry", category: "laundry", categoryKind: "chore", temporalState: "completed"),
                ParsedBlock(title: "lunch", category: "lunch", categoryKind: "meal", temporalState: "completed"),
                ParsedBlock(title: "walk", category: "walk", categoryKind: "exercise", temporalState: "completed"),
            ]),
            now: base + h(14), timeZone: tz, userId: "u1"
        )
        let laundry = try #require(try find(db, title: "laundry"))
        let walk = try #require(try find(db, title: "walk"))
        #expect(laundry.startAt == base + h(12, 30))   // 3 × 30m back from 14:00
        #expect(walk.endAt == base + h(14))
        // Yesterday untouched.
        let movie = try #require(try find(db, title: "movie"))
        #expect(movie.startAt == base - h(2))
        #expect(movie.endAt == base - h(1))
        #expect(movie.deletedAt == nil)
    }

    @Test func statedEveningTimeStaysCompactNoZeroLength() throws {
        let (db, svc) = try env()
        // "Played games at 11" said at 10:30 AM → 11 means last night 11 PM;
        // the block must be a modest one, never zero-length, never stretched.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "gaming", category: "gaming", categoryKind: "leisure",
                                               statedStart: "11", temporalState: "completed")]),
            now: base + h(10, 30), timeZone: tz, userId: "u1"
        )
        let gaming = try #require(try find(db, title: "gaming"))
        #expect(gaming.startAt == base - h(1))         // yesterday 23:00
        #expect(gaming.endAt == base - h(0, 30))       // 30-min default
        #expect(gaming.endAt! > gaming.startAt!)
    }

    @Test func matchingIgnoresPreviousDayPlanned() throws {
        let (db, svc) = try env()
        // Yesterday morning: "gym at 6pm" → planned yesterday 18:00. Never done.
        try svc.reconcile(
            ParsedCheckIn(blocks: [planned("gym", "gym", "exercise", start: "6pm")]),
            now: base - h(15), timeZone: tz, userId: "u1"
        )
        // Today: "done with the gym" → must create TODAY's block, not confirm
        // (and thereby move) yesterday's stale plan.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "gym", category: "gym", categoryKind: "exercise",
                                               temporalState: "completed")]),
            now: base + h(14), timeZone: tz, userId: "u1"
        )
        let events = try db.dbWriter.read {
            try Event.filter(Column("title") == "gym").order(Column("created_at")).fetchAll($0)
        }
        #expect(events.count == 2)
        #expect(events[0].state == EventState.planned.rawValue)   // yesterday's plan untouched
        #expect(events[0].startAt == base - h(6))
        #expect(events[1].state == EventState.confirmed.rawValue) // today's compact block
        #expect(events[1].startAt == base + h(13, 30))
        #expect(events[1].endAt == base + h(14))
    }

    @Test func inProgressContinuesFromStatedEndOfPreviousActivity() throws {
        let (db, svc) = try env()
        // "Worked from 9 to 10, and now I'm traveling." said at 10:37 —
        // travel picks up at 10:00, not at the moment of speaking.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "work", category: "Work", categoryKind: "work",
                            statedStart: "9", statedEnd: "10", temporalState: "completed"),
                ParsedBlock(title: "travel", category: "travel", categoryKind: "transit",
                            temporalState: "inProgress"),
            ]),
            now: base + h(10, 37), timeZone: tz, userId: "u1"
        )
        let work = try #require(try find(db, title: "work"))
        let travel = try #require(try find(db, title: "travel"))
        #expect(work.startAt == base + h(9))
        #expect(work.endAt == base + h(10))
        #expect(travel.startAt == base + h(10))     // continues the narration
        #expect(travel.endAt == nil)
        #expect(travel.confidence < 1.0)            // inferred → ≈ on the card
    }

    @Test func inProgressFallsBackToNowAfterALongGap() throws {
        let (db, svc) = try env()
        // "Worked 9 to 10" + "now gaming" said at 20:00 — 10 hours later is not
        // a continuation; gaming starts now.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "work", category: "Work", categoryKind: "work",
                            statedStart: "9am", statedEnd: "10am", temporalState: "completed"),
                ParsedBlock(title: "gaming", category: "gaming", categoryKind: "leisure",
                            temporalState: "inProgress"),
            ]),
            now: base + h(20), timeZone: tz, userId: "u1"
        )
        let gaming = try #require(try find(db, title: "gaming"))
        #expect(gaming.startAt == base + h(20))
    }

    @Test func sleepWorkCommuteScenario() throws {
        let (db, svc) = try env()
        // "Slept at 3, woke up at 9, did work until now, now commuting." at 14:00.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "sleep", category: "Sleep", categoryKind: "sleep",
                            statedStart: "3", statedEnd: "9", temporalState: "completed"),
                ParsedBlock(title: "work", category: "Work", categoryKind: "work",
                            statedStart: "9", statedEnd: "now", temporalState: "completed"),
                ParsedBlock(title: "commute", category: "commute", categoryKind: "transit",
                            temporalState: "inProgress"),
            ]),
            now: base + h(14), timeZone: tz, userId: "u1"
        )
        let sleep = try #require(try find(db, title: "sleep"))
        let work = try #require(try find(db, title: "work"))
        let commute = try #require(try find(db, title: "commute"))
        #expect(sleep.startAt == base + h(3))
        #expect(sleep.endAt == base + h(9))
        #expect(work.startAt == base + h(9))
        #expect(work.endAt == base + h(14))         // "until now" honored
        #expect(commute.startAt == base + h(14))
        #expect(commute.endAt == nil)               // the open block
        #expect(try EventRepository(db.dbWriter).plannedBlocks(userId: "u1").isEmpty)
    }

    @Test func voiceCannotTouchYesterdaysOpenBlockInTheMorning() throws {
        let (db, svc) = try env()
        // A block left "in progress" since yesterday 20:00 (maintenance hasn't run).
        try EventRepository(db.dbWriter).insert(Event(
            id: newID(), userId: "u1", categoryId: nil, title: "gaming", notes: nil,
            startAt: base - h(4), endAt: nil, state: EventState.confirmed.rawValue,
            sequenceHint: nil, confidence: 1.0, source: EventSource.voice.rawValue, sourceRef: nil,
            originCheckInId: nil, isPinned: false, createdAt: base - h(4), updatedAt: base - h(4), deletedAt: nil
        ))
        // 10 AM today: "done with gaming" — must NOT close yesterday's block.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "gaming", category: "gaming", categoryKind: "leisure",
                                               temporalState: "completed", closesOpenBlock: true)]),
            now: base + h(10), timeZone: tz, userId: "u1"
        )
        let events = try db.dbWriter.read {
            try Event.filter(Column("title") == "gaming").order(Column("created_at")).fetchAll($0)
        }
        #expect(events.count == 2)
        #expect(events[0].endAt == nil)              // yesterday's untouched
        #expect(events[1].endAt == base + h(10))     // today's compact block instead
    }

    @Test func lateNightVoiceStillClosesThisEveningsBlock() throws {
        let (db, svc) = try env()
        // "Watching a movie" open since 22:00; at 00:30 (small hours of the NEXT
        // day, same wake period): "done with the movie" closes it.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "movie", category: "movie", categoryKind: "leisure",
                                               statedStart: "10pm", temporalState: "inProgress")]),
            now: base + h(22), timeZone: tz, userId: "u1"
        )
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "movie", category: "movie", categoryKind: "leisure",
                                               temporalState: "completed", closesOpenBlock: true)]),
            now: base + h(24, 30), timeZone: tz, userId: "u1"
        )
        let movie = try #require(try find(db, title: "movie"))
        #expect(movie.endAt == base + h(24, 30))
    }

    @Test func plannedWedgedBetweenPastAndPresentBecomesCompleted() throws {
        let (db, svc) = try env()
        // "Finished lunch, put my laundry in, and now I'm working." — the model
        // sometimes misfiles the quick middle action as "planned".
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "lunch", category: "lunch", categoryKind: "meal", temporalState: "completed"),
                ParsedBlock(title: "laundry", category: "laundry", categoryKind: "chore", temporalState: "planned"),
                ParsedBlock(title: "work", category: "Work", categoryKind: "work", temporalState: "inProgress"),
            ]),
            now: base + h(14), timeZone: tz, userId: "u1"
        )
        let laundry = try #require(try find(db, title: "laundry"))
        #expect(laundry.state == EventState.confirmed.rawValue)   // reclassified
        #expect(laundry.endAt == base + h(14))
        let work = try #require(try find(db, title: "work"))
        #expect(work.startAt == base + h(14))
        #expect(work.endAt == nil)
        #expect(try EventRepository(db.dbWriter).plannedBlocks(userId: "u1").isEmpty)
    }

    @Test func trailingPlannedStaysPlanned() throws {
        let (db, svc) = try env()
        // "Finished lunch, then I'll hit the gym." — trailing plan must survive.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "lunch", category: "lunch", categoryKind: "meal", temporalState: "completed"),
                ParsedBlock(title: "gym", category: "gym", categoryKind: "exercise", temporalState: "planned"),
            ]),
            now: base + h(13), timeZone: tz, userId: "u1"
        )
        let gym = try #require(try find(db, title: "gym"))
        #expect(gym.state == EventState.planned.rawValue)
    }

    @Test func quickTaskSqueezedAgainstNowBecomesASliver() throws {
        let (db, svc) = try env()
        // Shower has been the open block since 13:40.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "shower", category: "shower", categoryKind: "chore",
                                               statedStart: "1:40pm", temporalState: "inProgress")]),
            now: base + h(13, 40), timeZone: tz, userId: "u1"
        )
        // "Just finished showering, put my laundry in, now doing work." at 14:00.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "shower", category: "shower", categoryKind: "chore",
                            temporalState: "completed", closesOpenBlock: true),
                ParsedBlock(title: "laundry", category: "laundry", categoryKind: "chore",
                            temporalState: "completed"),
                ParsedBlock(title: "work", category: "Work", categoryKind: "work",
                            temporalState: "inProgress"),
            ]),
            now: base + h(14), timeZone: tz, userId: "u1"
        )
        let shower = try #require(try find(db, title: "shower"))
        let laundry = try #require(try find(db, title: "laundry"))
        let work = try #require(try find(db, title: "work"))
        #expect(shower.endAt == base + h(14))              // closed at now
        #expect(laundry.endAt == base + h(14))
        #expect(laundry.startAt == base + h(13, 59))       // 1-min sliver, not 30 min under the shower
        #expect(work.startAt == base + h(14))
        #expect(work.endAt == nil)
    }

    @Test func wakeUpAnchorSkippedWhenSleepBlockPresent() throws {
        let (db, svc) = try env()
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "movie", category: "movie", categoryKind: "leisure",
                                               statedStart: "10pm", statedEnd: "11pm", temporalState: "completed")]),
            now: base - h(1), timeZone: tz, userId: "u1"
        )
        // Model double-reports: a completed sleep block AND a wakeUp anchor.
        try svc.reconcile(
            ParsedCheckIn(
                blocks: [ParsedBlock(title: "sleep", category: "Sleep", categoryKind: "sleep",
                                     statedStart: "11pm", statedEnd: "7am", temporalState: "completed")],
                anchors: [ParsedAnchor(kind: "wakeUp")]
            ),
            now: base + h(7, 30), timeZone: tz, userId: "u1"
        )
        let sleeps = try db.dbWriter.read {
            try Event.filter(Column("title").like("sleep")).filter(Column("deleted_at") == nil).fetchAll($0)
        }
        #expect(sleeps.count == 1)                     // exactly one, not two
        #expect(sleeps[0].startAt == base - h(1))
        #expect(sleeps[0].endAt == base + h(7))
    }

    @Test func wakeUpDoesNotDuplicateExistingSleep() throws {
        let (db, svc) = try env()
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "movie", category: "movie", categoryKind: "leisure",
                                               statedStart: "10pm", statedEnd: "11pm", temporalState: "completed")]),
            now: base - h(1), timeZone: tz, userId: "u1"
        )
        try svc.reconcile(ParsedCheckIn(anchors: [ParsedAnchor(kind: "wakeUp")]),
                          now: base + h(7, 30), timeZone: tz, userId: "u1")
        // Saying "just woke up" again later must not add a second sleep block.
        try svc.reconcile(ParsedCheckIn(anchors: [ParsedAnchor(kind: "wakeUp")]),
                          now: base + h(9), timeZone: tz, userId: "u1")
        let sleeps = try db.dbWriter.read {
            try Event.filter(Column("title") == "Sleep").filter(Column("deleted_at") == nil).fetchAll($0)
        }
        #expect(sleeps.count == 1)
    }

    @Test func chainEndsWhereInProgressBegins() throws {
        let (db, svc) = try env()
        // "Finished homework, been cooking since 7." at 19:30.
        try svc.reconcile(
            ParsedCheckIn(blocks: [
                ParsedBlock(title: "homework", category: "homework", categoryKind: "work", temporalState: "completed"),
                ParsedBlock(title: "cooking", category: "cooking", categoryKind: "chore",
                            statedStart: "7", temporalState: "inProgress"),
            ]),
            now: base + h(19, 30), timeZone: tz, userId: "u1"
        )
        let hw = try #require(try find(db, title: "homework"))
        let cook = try #require(try find(db, title: "cooking"))
        #expect(hw.endAt == base + h(19))            // chain ends where cooking starts
        #expect(cook.startAt == base + h(19))
        #expect(cook.endAt == nil)                   // cooking is the open block
    }

    @Test func mislabeledStateStringStillCompletes() throws {
        let (db, svc) = try env()
        // The model said "Completed" (capitalized) — must not silently become planned.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "run", category: "run", categoryKind: "exercise",
                                               statedDuration: "30 minutes", temporalState: "Completed")]),
            now: base + h(9), timeZone: tz, userId: "u1"
        )
        let run = try #require(try find(db, title: "run"))
        #expect(run.state == EventState.confirmed.rawValue)
        #expect(run.endAt == base + h(9))
        #expect(run.startAt == base + h(8, 30))
    }

    @Test func wakeUpWithNoSleepBlockCreatesOvernightSleep() throws {
        let (db, svc) = try env()
        // Last thing logged yesterday ended at 23:00.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "movie", category: "movie", categoryKind: "leisure",
                                               statedStart: "10pm", statedEnd: "11pm", temporalState: "completed")]),
            now: base - h(1), timeZone: tz, userId: "u1"
        )
        // "Just woke up." at 7:30 → sleep block 23:00–07:30 appears.
        try svc.reconcile(
            ParsedCheckIn(anchors: [ParsedAnchor(kind: "wakeUp")]),
            now: base + h(7, 30), timeZone: tz, userId: "u1"
        )
        let sleep = try #require(try find(db, title: "Sleep"))
        #expect(sleep.startAt == base - h(1))
        #expect(sleep.endAt == base + h(7, 30))
        #expect(sleep.state == EventState.confirmed.rawValue)
    }

    @Test func skipWithoutTargetHintIsNoOp() throws {
        let (db, svc) = try env()
        try svc.reconcile(ParsedCheckIn(blocks: [planned("run", "run", "exercise")]),
                          now: base + h(9), timeZone: tz, userId: "u1")
        // "Skipped it" with no recoverable target must not delete an arbitrary block.
        try svc.reconcile(ParsedCheckIn(anchors: [ParsedAnchor(kind: "skip")]),
                          now: base + h(12), timeZone: tz, userId: "u1")
        #expect(try EventRepository(db.dbWriter).plannedBlocks(userId: "u1").count == 1)
    }

    @Test func completedMatchesPlannedByTitleOverCategory() throws {
        let (db, svc) = try env()
        try svc.reconcile(ParsedCheckIn(blocks: [
            planned("run", "run", "exercise"),
            planned("lift", "lift", "exercise"),
        ]), now: base + h(9), timeZone: tz, userId: "u1")
        // "Done with the lift." — must confirm lift, not the first exercise block.
        try svc.reconcile(
            ParsedCheckIn(blocks: [ParsedBlock(title: "lift", category: "lift", categoryKind: "exercise",
                                               temporalState: "completed")]),
            now: base + h(11), timeZone: tz, userId: "u1"
        )
        let lift = try #require(try find(db, title: "lift"))
        let run = try #require(try find(db, title: "run"))
        #expect(lift.state == EventState.confirmed.rawValue)
        #expect(run.state == EventState.planned.rawValue)
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
