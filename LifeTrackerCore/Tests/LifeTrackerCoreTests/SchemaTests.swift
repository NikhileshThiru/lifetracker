import Foundation
import Testing
import GRDB
@testable import LifeTrackerCore

struct SchemaTests {
    @Test func migrationCreatesAllTables() throws {
        let appDB = try AppDatabase.makeInMemory()
        let expected = [
            "meta", "users", "categories", "check_ins", "parse_runs",
            "events", "event_revisions", "goals", "goal_progress",
            "daily_summaries", "intents", "data_sources", "health_samples",
            "settings", "sync_state",
        ]
        try appDB.dbWriter.read { db in
            for table in expected {
                let exists = try db.tableExists(table)
                #expect(exists, "missing table: \(table)")
            }
        }
    }

    @Test func migrationCreatesAllIndexes() throws {
        let appDB = try AppDatabase.makeInMemory()
        let expected = [
            "idx_events_start", "idx_events_open", "idx_events_category",
            "idx_events_state", "idx_events_sourceref", "idx_revisions_batch",
            "idx_health_hkuuid",
        ]
        try appDB.dbWriter.read { db in
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type='index'"
            )
            for index in expected {
                #expect(names.contains(index), "missing index: \(index)")
            }
        }
    }

    @Test func seedsSchemaVersionUserAndDefaultCategories() throws {
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let version = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'schema_version'"
            )
            #expect(version == "1")

            let users = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? 0
            #expect(users == 1)

            let defaults = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM categories WHERE is_default = 1"
            ) ?? 0
            #expect(defaults == 9)
        }
    }

    @Test func backupProducesReadableCopy() throws {
        let db = try AppDatabase.makeInMemory()
        let url = FileManager.default.temporaryDirectory.appending(path: "lt-backup-\(newID()).sqlite")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try db.backup(to: url)
        let restored = try AppDatabase.make(atPath: url.path)
        let count = try restored.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM categories WHERE is_default = 1")
        }
        #expect(count == 9)
    }

    @Test func softDeleteLeavesTombstone() throws {
        let appDB = try AppDatabase.makeInMemory()
        let now = Clock.nowMillis()
        let id = newID()

        try appDB.dbWriter.write { db in
            try db.execute(
                sql: """
                INSERT INTO categories
                  (id, name, kind, is_default, created_by, sort_order, is_archived, created_at, updated_at)
                VALUES (?, 'Swimming', 'exercise', 0, 'auto', 100, 0, ?, ?)
                """,
                arguments: [id, now, now]
            )
            try db.execute(
                sql: "UPDATE categories SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }

        try appDB.dbWriter.read { db in
            let live = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM categories WHERE id = ? AND deleted_at IS NULL",
                arguments: [id]
            ) ?? -1
            #expect(live == 0, "soft-deleted row should not appear as live")

            let total = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM categories WHERE id = ?", arguments: [id]
            ) ?? -1
            #expect(total == 1, "tombstone row should still exist (never hard-deleted)")
        }
    }
}
