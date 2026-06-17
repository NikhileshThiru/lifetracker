import Foundation
import Observation
import LifeTrackerCore

/// One renderable row on the day timeline: a real event, or a computed gap.
enum TimelineItem: Identifiable {
    case event(Event, LifeTrackerCore.Category?)
    case gap(Gap)
    case nowMarker(Int64)

    var id: String {
        switch self {
        case .event(let e, _): return "e_" + e.id
        case .gap(let g): return "g_\(g.startAt)_\(g.endAt)"
        case .nowMarker: return "now"
        }
    }

    var sortKey: Int64 {
        switch self {
        case .event(let e, _): return e.startAt ?? .max
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

        var merged: [TimelineItem] = timed.map { .event($0, $0.categoryId.flatMap { catMap[$0] }) }
        merged += gaps.map { .gap($0) }
        let (dayStart, dayEnd) = day.bounds(in: tz)
        if now >= dayStart && now < dayEnd { merged.append(.nowMarker(now)) }
        merged.sort { $0.sortKey < $1.sortKey }
        items = merged

        trackedMinutes = timed.reduce(0) { acc, e in
            guard e.state == EventState.confirmed.rawValue, let s = e.startAt else { return acc }
            let end = e.endAt ?? now
            return acc + max(0, Int((end - s) / 60_000))
        }
        gapCount = gaps.count

        let planned = (try? repo.plannedBlocks()) ?? []
        laterPlanned = planned
            .filter { $0.startAt == nil }
            .map { ($0, $0.categoryId.flatMap { catMap[$0] }) }

        title = TimeFormat.dayTitle(dayStart, tz: tz)
    }
}
