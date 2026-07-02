import Foundation
import Observation
import LifeTrackerCore

/// An event as it renders on one specific day: times are clipped to that day so an
/// activity crossing midnight shows only its slice (with continuation markers).
struct EventLayout: Identifiable {
    let event: Event
    let category: LifeTrackerCore.Category?
    let displayStart: Int64?   // clipped to the day; nil only for loose blocks
    let displayEnd: Int64?     // clipped to the day; nil = open / in progress
    let continuesBefore: Bool  // began on an earlier day
    let continuesAfter: Bool   // spills into a later day
    var id: String { event.id }
}

/// One renderable row on the day timeline: a real event, or a computed gap.
enum TimelineItem: Identifiable {
    case event(EventLayout)
    case gap(Gap)
    case nowMarker(Int64)

    var id: String {
        switch self {
        case .event(let l): return "e_" + l.event.id
        case .gap(let g): return "g_\(g.startAt)_\(g.endAt)"
        case .nowMarker: return "now"
        }
    }

    var sortKey: Int64 {
        switch self {
        case .event(let l): return l.displayStart ?? .max
        case .gap(let g): return g.startAt
        case .nowMarker(let ms): return ms
        }
    }
}

@Observable
final class TimelineModel {
    var items: [TimelineItem] = []
    var laterPlanned: [(event: Event, category: LifeTrackerCore.Category?)] = []
    var title: String = "Today"
    var trackedMinutes = 0
    var gapCount = 0

    var isEmpty: Bool { items.isEmpty && laterPlanned.isEmpty }

    /// Compact day summary, e.g. "6h 15m logged · 2 gaps".
    var summaryLine: String? {
        guard trackedMinutes > 0 || gapCount > 0 else { return nil }
        var parts: [String] = []
        if trackedMinutes > 0 { parts.append("\(TimeFormat.duration(Int64(trackedMinutes) * 60_000)) logged") }
        if gapCount > 0 { parts.append("\(gapCount) gap\(gapCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    func load(database: AppDatabase, day: LocalDay, now: Int64, tz: TimeZone) {
        var catMap: [String: LifeTrackerCore.Category] = [:]
        for c in (try? CategoryRepository(database.dbWriter).live()) ?? [] { catMap[c.id] = c }

        let repo = EventRepository(database.dbWriter)
        let timed = (try? repo.events(on: day, tz: tz)) ?? []
        let gaps = GapCalculator.gaps(events: timed, day: day, timeZone: tz, now: now)
        let (dayStart, dayEnd) = day.bounds(in: tz)

        let layouts = timed.map { e -> EventLayout in
            EventLayout(
                event: e,
                category: e.categoryId.flatMap { catMap[$0] },
                displayStart: e.startAt.map { max($0, dayStart) },
                displayEnd: e.endAt.map { min($0, dayEnd) },
                continuesBefore: e.continuesBefore(dayStart),
                continuesAfter: e.continuesAfter(dayEnd, now: now)
            )
        }

        var merged: [TimelineItem] = layouts.map { .event($0) }
        merged += gaps.map { .gap($0) }
        if now >= dayStart && now < dayEnd { merged.append(.nowMarker(now)) }
        merged.sort { $0.sortKey < $1.sortKey }
        items = merged

        // Union coverage: overlapping blocks can't double-count, so the day's
        // "logged" total is honest and can never exceed 24h.
        trackedMinutes = GapCalculator.coveredMinutes(events: timed, day: day, timeZone: tz, now: now)
        gapCount = gaps.count

        let planned = (try? repo.plannedBlocks()) ?? []
        laterPlanned = planned
            .filter { $0.startAt == nil }
            .map { ($0, $0.categoryId.flatMap { catMap[$0] }) }

        title = TimeFormat.dayTitle(dayStart, tz: tz)
    }
}
