import Foundation
import GRDB

/// Owns the GRDB connection and applies migrations on creation.
///
/// All feature code goes through this type (or repositories built on its
/// `dbWriter`) so persistence stays behind one seam — keeping the door open
/// for a future sync layer without touching features.
public final class AppDatabase {
    /// The GRDB writer (a `DatabaseQueue` here). `DatabaseWriter` is the
    /// protocol so this can be swapped (e.g. a pool) later.
    public let dbWriter: any DatabaseWriter

    /// Creates the database and runs all pending migrations.
    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    /// In-memory database, for tests and SwiftUI previews.
    public static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    /// File-backed database at `path`, for app use.
    public static func make(atPath path: String) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        return try AppDatabase(queue)
    }

    /// Writes a consistent single-file copy of the database to `url` (for export/backup).
    /// Uses `VACUUM INTO`, so the copy is clean regardless of journal mode.
    public func backup(to url: URL) throws {
        try dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    public enum RestoreError: Error { case notALifeTrackerBackup }

    /// Replaces this database's contents with those from a backup file at `url`
    /// (produced by `backup(to:)`), then re-applies migrations so an older backup is
    /// brought up to the current schema. Uses SQLite's online backup API, so the live
    /// connection stays valid and in-place — no app restart needed.
    ///
    /// Validates the source looks like a Life Tracker backup *before* overwriting, so a
    /// wrong file picked in the document browser can't clobber real data.
    public func restore(from url: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let source = try DatabaseQueue(path: url.path, configuration: config)
        let looksValid = try source.read { db in
            try db.tableExists("events") && db.tableExists("categories") && db.tableExists("meta")
        }
        guard looksValid else { throw RestoreError.notALifeTrackerBackup }
        try source.backup(to: dbWriter)
        try migrator.migrate(dbWriter)
    }
}
