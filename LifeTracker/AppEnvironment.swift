import Foundation
import Observation
import LifeTrackerCore

/// App-wide environment: the on-device database, timezone, and current time.
/// In demo mode (`-seedDemo` launch arg) it uses an in-memory DB seeded with a
/// sample day and a fixed "now", so the UI is reproducible without touching real data.
/// `@unchecked Sendable`: every stored property is immutable (`let`) and the
/// database writer is itself Sendable.
@Observable
final class AppEnvironment: @unchecked Sendable {
    let database: AppDatabase
    let timeZone: TimeZone
    private let fixedNow: Int64?

    init(database: AppDatabase, timeZone: TimeZone = .current, fixedNow: Int64? = nil) {
        self.database = database
        self.timeZone = timeZone
        self.fixedNow = fixedNow
    }

    func currentTime() -> Int64 { fixedNow ?? Clock.nowMillis() }

    /// When the user last logged anything (check-in or event), for the idle reminder.
    func lastActivityMillis() -> Int64? {
        let lastEvent = (try? EventRepository(database.dbWriter).lastCreatedAt()) ?? nil
        let lastCheckIn = (try? CheckInRepository(database.dbWriter).lastOccurredAt()) ?? nil
        return [lastEvent, lastCheckIn].compactMap { $0 }.max()
    }

    /// Daily rollover, run when the app comes to the foreground: expire planned
    /// blocks from past days that were never confirmed, and close blocks left
    /// open ("in progress") on a previous day.
    func runMaintenance() {
        let service = TimelineService(database.dbWriter)
        _ = try? service.expireStalePlanned(asOf: currentTime(), timeZone: timeZone)
        _ = try? service.closeStaleOpenBlocks(asOf: currentTime(), timeZone: timeZone)
    }

    /// (Re)schedules the inactivity nudge from current settings + last activity.
    func rescheduleIdleReminder() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "reminderEnabled")
        let stored = defaults.integer(forKey: "idleHours")
        ReminderScheduler.reschedule(
            enabled: enabled,
            idleHours: stored == 0 ? 4 : stored,
            lastActivity: lastActivityMillis(),
            now: currentTime(),
            timeZone: timeZone
        )
    }

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
