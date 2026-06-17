import Foundation
import Observation
import LifeTrackerCore

/// One renderable row on the day timeline: a real event, or a computed gap.
enum TimelineItem: Identifiable {
    case event(Event, LifeTrackerCore.Category?)
    case gap(Gap)

    var id: String {
        switch self {
        case .event(let e, _): return "e_" + e.id
        case .gap(let g): return "g_\(g.startAt)_\(g.endAt)"
        }
    }

    var sortKey: Int64 {
        switch self {
        case .event(let e, _): return e.startAt ?? .max
        case .gap(let g): return g.startAt
        }
    }
}

@Observable
final class TimelineModel {
    var items: [TimelineItem] = []
    var laterPlanned: [(event: Event, category: LifeTrackerCore.Category?)] = []
    var title: String = "Today"

    var isEmpty: Bool { items.isEmpty && laterPlanned.isEmpty }

    func load(database: AppDatabase, day: LocalDay, now: Int64, tz: TimeZone) {
        var catMap: [String: LifeTrackerCore.Category] = [:]
        for c in (try? CategoryRepository(database.dbWriter).live()) ?? [] { catMap[c.id] = c }

        let repo = EventRepository(database.dbWriter)
        let timed = (try? repo.events(on: day, tz: tz)) ?? []
        let gaps = GapCalculator.gaps(events: timed, day: day, timeZone: tz, now: now)

        var merged: [TimelineItem] = timed.map { .event($0, $0.categoryId.flatMap { catMap[$0] }) }
        merged += gaps.map { .gap($0) }
        merged.sort { $0.sortKey < $1.sortKey }
        items = merged

        let planned = (try? repo.plannedBlocks()) ?? []
        laterPlanned = planned
            .filter { $0.startAt == nil }
            .map { ($0, $0.categoryId.flatMap { catMap[$0] }) }

        title = TimeFormat.dayTitle(day.bounds(in: tz).startMs, tz: tz)
    }
}
