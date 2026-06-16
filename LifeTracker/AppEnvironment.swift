import Foundation
import Observation
import LifeTrackerCore

/// App-wide environment: the on-device database, timezone, and current time.
/// In demo mode (`-seedDemo` launch arg) it uses an in-memory DB seeded with a
/// sample day and a fixed "now", so the UI is reproducible without touching real data.
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let timeZone: TimeZone
    private let fixedNow: Int64?

    init(database: AppDatabase, timeZone: TimeZone = .current, fixedNow: Int64? = nil) {
        self.database = database
        self.timeZone = timeZone
        self.fixedNow = fixedNow
    }

    func currentTime() -> Int64 { fixedNow ?? Clock.nowMillis() }

    static func live() -> AppEnvironment {
        let tz = TimeZone.current
        if ProcessInfo.processInfo.arguments.contains("-seedDemo") {
            let db = try! AppDatabase.makeInMemory()
            let demoNow = LocalDay(containing: Date(), in: tz).bounds(in: tz).startMs
                + 15 * 3_600_000 + 30 * 60_000   // today 3:30 PM
            DemoData.seed(db, now: demoNow, tz: tz)
            return AppEnvironment(database: db, timeZone: tz, fixedNow: demoNow)
        }
        let url = URL.documentsDirectory.appending(path: "lifetracker.sqlite")
        let db = try! AppDatabase.make(atPath: url.path)
        return AppEnvironment(database: db, timeZone: tz)
    }
}
