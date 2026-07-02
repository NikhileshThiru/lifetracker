import Foundation
import Observation
import LifeTrackerCore

@Observable
final class StatsModel {
    struct Row: Identifiable {
        let id: String
        let name: String
        let colorHex: String?
        let todayMinutes: Int
        let weekMinutes: Int
    }

    var rows: [Row] = []
    var streakDays: Int = 0

    func load(database: AppDatabase, tz: TimeZone, now: Int64) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let today = LocalDay(containing: Clock.date(fromMillis: now), in: tz)
        let (todayStart, todayEnd) = today.bounds(in: tz)
        let todayStartDate = Clock.date(fromMillis: todayStart)
        let weekStart = Clock.millis(from: cal.date(byAdding: .day, value: -6, to: todayStartDate)!)
        let streakWindowStart = Clock.millis(from: cal.date(byAdding: .day, value: -60, to: todayStartDate)!)

        var catMap: [String: LifeTrackerCore.Category] = [:]
        for cat in (try? CategoryRepository(database.dbWriter).live()) ?? [] { catMap[cat.id] = cat }

        let repo = EventRepository(database.dbWriter)
        // Overlap query so overnight blocks from a prior day contribute their slice.
        let weekEvents = (try? repo.confirmedOverlapping(in: weekStart..<todayEnd)) ?? []

        var todayMin: [String: Int] = [:]
        var weekMin: [String: Int] = [:]
        for e in weekEvents {
            guard let cid = e.categoryId else { continue }
            weekMin[cid, default: 0] += e.minutes(in: weekStart, todayEnd, now: now)
            todayMin[cid, default: 0] += e.minutes(in: todayStart, todayEnd, now: now)
        }

        rows = weekMin.keys.compactMap { cid -> Row? in
            guard let cat = catMap[cid] else { return nil }
            return Row(id: cid, name: cat.name, colorHex: cat.colorHex,
                       todayMinutes: todayMin[cid] ?? 0, weekMinutes: weekMin[cid] ?? 0)
        }
        .sorted { $0.weekMinutes > $1.weekMinutes }

        // Trailing streak: consecutive days (ending today) with any confirmed log.
        // Mark both the start day and end day so an overnight block counts for both.
        let streakEvents = (try? repo.confirmedOverlapping(in: streakWindowStart..<todayEnd)) ?? []
        var daysWithData = Set<String>()
        for e in streakEvents {
            guard let s = e.startAt else { continue }
            daysWithData.insert(LocalDay(containing: Clock.date(fromMillis: s), in: tz).id)
            let end = e.endAt ?? now
            daysWithData.insert(LocalDay(containing: Clock.date(fromMillis: end), in: tz).id)
        }
        var streak = 0
        var cursor = todayStartDate
        while daysWithData.contains(LocalDay(containing: cursor, in: tz).id) {
            streak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        streakDays = streak
    }
}
