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
}
