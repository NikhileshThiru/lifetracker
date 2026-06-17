import Foundation
import LifeTrackerCore

/// Seeds a believable sample day for screenshots/demo (only used with `-seedDemo`).
enum DemoData {
    static func seed(_ db: AppDatabase, now: Int64, tz: TimeZone) {
        let repo = EventRepository(db.dbWriter)
        let cats = (try? CategoryRepository(db.dbWriter).live()) ?? []
        func cat(_ kind: CategoryKind) -> String? { cats.first { $0.kind == kind.rawValue }?.id }

        let base = LocalDay(containing: Clock.date(fromMillis: now), in: tz).bounds(in: tz).startMs
        func at(_ h: Int, _ m: Int = 0) -> Int64 { base + Int64(h) * 3_600_000 + Int64(m) * 60_000 }

        func ev(_ title: String, _ kind: CategoryKind, _ start: Int64?, _ end: Int64?, _ state: EventState, seq: Int? = nil) -> Event {
            Event(id: newID(), userId: nil, categoryId: cat(kind), title: title, notes: nil,
                  startAt: start, endAt: end, state: state.rawValue, sequenceHint: seq,
                  confidence: state == .planned ? 0.6 : 1.0, source: EventSource.voice.rawValue,
                  sourceRef: nil, originCheckInId: nil, isPinned: false,
                  createdAt: now, updatedAt: now, deletedAt: nil)
        }

        let day: [Event] = [
            ev("Sleep", .sleep, at(0), at(7, 30), .confirmed),
            ev("Breakfast", .meal, at(8), at(8, 30), .confirmed),
            ev("Deep work", .work, at(9), at(12, 30), .confirmed),
            ev("Lunch", .meal, at(13), at(13, 45), .confirmed),
            ev("Emails & calls", .work, at(14), nil, .confirmed),   // open / in progress
            ev("Gym", .exercise, at(18), at(19), .planned),         // upcoming, dashed
            ev("Read", .leisure, nil, nil, .planned, seq: 1),       // loose placeholder
        ]
        for e in day { try? repo.insert(e) }

        // One unsorted check-in (AI-unavailable fallback) to demo the inbox.
        try? CheckInRepository(db.dbWriter).insert(CheckIn(
            id: newID(), userId: nil, occurredAt: at(15, 5), timezone: tz.identifier,
            rawTranscript: "grabbed a quick coffee with Sam, didn't catch the rest",
            audioPath: nil, sttEngine: "speechanalyzer", inputMethod: "voice",
            parseStatus: ParseStatus.manual.rawValue, createdAt: now, updatedAt: now, deletedAt: nil
        ))
    }
}
