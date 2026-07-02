import Foundation
import Testing
import GRDB
@testable import LifeTrackerCore

struct RestoreTests {
    private func event(_ id: String, now: Int64) -> Event {
        Event(id: id, userId: "u1", categoryId: nil, title: id, notes: nil,
              startAt: now, endAt: now + 3_600_000, state: EventState.confirmed.rawValue,
              sequenceHint: nil, confidence: 1, source: EventSource.voice.rawValue, sourceRef: nil,
              originCheckInId: nil, isPinned: false, createdAt: now, updatedAt: now, deletedAt: nil)
    }

    @Test func restoreReplacesContentsWithBackup() throws {
        let db = try AppDatabase.makeInMemory()
        let events = EventRepository(db.dbWriter)
        let now = Clock.nowMillis()
        try events.insert(event("keep", now: now))

        let backupURL = FileManager.default.temporaryDirectory.appending(path: "restore-\(now).sqlite")
        try? FileManager.default.removeItem(at: backupURL)
        try db.backup(to: backupURL)
        defer { try? FileManager.default.removeItem(at: backupURL) }

        // Change the DB after the backup was taken.
        try events.insert(event("stray", now: now))
        #expect(try events.find(id: "stray") != nil)

        try db.restore(from: backupURL)

        #expect(try events.find(id: "keep") != nil)   // backed-up data is present
        #expect(try events.find(id: "stray") == nil)  // post-backup change is gone
    }

    @Test func restoreRejectsFileThatIsNotALifeTrackerBackup() throws {
        let db = try AppDatabase.makeInMemory()
        let now = Clock.nowMillis()
        try EventRepository(db.dbWriter).insert(event("original", now: now))

        let bogus = FileManager.default.temporaryDirectory.appending(path: "bogus-\(now).sqlite")
        try? FileManager.default.removeItem(at: bogus)
        let q = try DatabaseQueue(path: bogus.path)
        try q.write { db in try db.execute(sql: "CREATE TABLE random(x)") }
        defer { try? FileManager.default.removeItem(at: bogus) }

        #expect(throws: AppDatabase.RestoreError.self) {
            try db.restore(from: bogus)
        }
        // Real data untouched after a rejected restore.
        #expect(try EventRepository(db.dbWriter).find(id: "original") != nil)
    }
}
