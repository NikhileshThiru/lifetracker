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
        let weekEvents = (try? repo.confirmed(in: weekStart..<todayEnd)) ?? []

        var todayMin: [String: Int] = [:]
        var weekMin: [String: Int] = [:]
        for e in weekEvents {
            guard let s = e.startAt, let cid = e.categoryId else { continue }
            let end = e.endAt ?? now
            let mins = max(0, Int((end - s) / 60_000))
            weekMin[cid, default: 0] += mins
            if s >= todayStart && s < todayEnd { todayMin[cid, default: 0] += mins }
        }

        rows = weekMin.keys.compactMap { cid -> Row? in
            guard let cat = catMap[cid] else { return nil }
            return Row(id: cid, name: cat.name, colorHex: cat.colorHex,
                       todayMinutes: todayMin[cid] ?? 0, weekMinutes: weekMin[cid] ?? 0)
        }
        .sorted { $0.weekMinutes > $1.weekMinutes }

        // Trailing streak: consecutive days (ending today) with any confirmed log.
        let streakEvents = (try? repo.confirmed(in: streakWindowStart..<todayEnd)) ?? []
        var daysWithData = Set<String>()
        for e in streakEvents {
            if let s = e.startAt { daysWithData.insert(LocalDay(containing: Clock.date(fromMillis: s), in: tz).id) }
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
