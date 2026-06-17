import Foundation
import Observation
import LifeTrackerCore

@Observable
final class MonthModel {
    struct DayCell: Identifiable {
        let id: Int
        let day: LocalDay?
        let dayNumber: Int?
        let trackedMinutes: Int
        let topColorHex: String?
        let isToday: Bool
    }

    var title: String = ""
    var cells: [DayCell] = []
    private(set) var year: Int
    private(set) var month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    func shift(by months: Int, database: AppDatabase, tz: TimeZone, now: Int64) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        if let base = cal.date(from: c), let shifted = cal.date(byAdding: .month, value: months, to: base) {
            let comps = cal.dateComponents([.year, .month], from: shifted)
            year = comps.year!
            month = comps.month!
        }
        load(database: database, tz: tz, now: now)
    }

    func load(database: AppDatabase, tz: TimeZone, now: Int64) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        guard let first = cal.date(from: c) else { return }

        let leading = cal.component(.weekday, from: first) - 1   // Sunday = 1
        let dayCount = cal.range(of: .day, in: .month, for: first)!.count

        let tf = DateFormatter(); tf.timeZone = tz; tf.dateFormat = "MMMM yyyy"
        title = tf.string(from: first)

        let monthStart = Clock.millis(from: first)
        let monthEnd = Clock.millis(from: cal.date(byAdding: .month, value: 1, to: first)!)

        var catMap: [String: LifeTrackerCore.Category] = [:]
        for cat in (try? CategoryRepository(database.dbWriter).live()) ?? [] { catMap[cat.id] = cat }
        let events = (try? EventRepository(database.dbWriter).confirmed(in: monthStart..<monthEnd)) ?? []

        var dayMinutes: [Int: Int] = [:]
        var dayCatMinutes: [Int: [String: Int]] = [:]
        for e in events {
            guard let s = e.startAt else { continue }
            let dayNum = LocalDay(containing: Clock.date(fromMillis: s), in: tz).day
            let end = e.endAt ?? now
            let mins = max(0, Int((end - s) / 60_000))
            dayMinutes[dayNum, default: 0] += mins
            if let cid = e.categoryId { dayCatMinutes[dayNum, default: [:]][cid, default: 0] += mins }
        }

        let today = LocalDay(containing: Clock.date(fromMillis: now), in: tz)
        var result: [DayCell] = []
        for i in 0..<leading {
            result.append(DayCell(id: i, day: nil, dayNumber: nil, trackedMinutes: 0, topColorHex: nil, isToday: false))
        }
        for d in 1...dayCount {
            let topCat = dayCatMinutes[d]?.max(by: { $0.value < $1.value })?.key
            let ld = LocalDay(year: year, month: month, day: d)
            result.append(DayCell(
                id: 1000 + d, day: ld, dayNumber: d,
                trackedMinutes: dayMinutes[d] ?? 0,
                topColorHex: topCat.flatMap { catMap[$0]?.colorHex },
                isToday: ld == today
            ))
        }
        cells = result
    }
}
