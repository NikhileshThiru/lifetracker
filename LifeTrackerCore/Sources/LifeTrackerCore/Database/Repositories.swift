import Foundation
import GRDB

// Concrete repositories over an injectable `DatabaseWriter`. The DB seam itself
// (AppDatabase / DatabaseWriter) is what a future sync layer plugs into; if a
// second backend ever appears, these extract to protocols without touching callers.

// MARK: - Categories

public struct CategoryRepository {
    let dbWriter: any DatabaseWriter
    public init(_ dbWriter: any DatabaseWriter) { self.dbWriter = dbWriter }

    public func insert(_ category: Category) throws {
        try dbWriter.write { try category.insert($0) }
    }

    public func update(_ category: Category, now: Int64 = Clock.nowMillis()) throws {
        var c = category
        c.updatedAt = now
        try dbWriter.write { try c.update($0) }
    }

    public func find(id: String) throws -> Category? {
        try dbWriter.read { try Category.fetchOne($0, key: id) }
    }

    /// All non-deleted, non-archived categories, ordered for display.
    public func live() throws -> [Category] {
        try dbWriter.read { db in
            try Category
                .filter(Column("deleted_at") == nil)
                .filter(Column("is_archived") == false)
                .order(Column("sort_order"), Column("name"))
                .fetchAll(db)
        }
    }

    public func softDelete(id: String, now: Int64 = Clock.nowMillis()) throws {
        _ = try dbWriter.write { db in
            try Category
                .filter(Column("id") == id)
                .updateAll(db, Column("deleted_at").set(to: now), Column("updated_at").set(to: now))
        }
    }
}

// MARK: - Check-ins

public struct CheckInRepository {
    let dbWriter: any DatabaseWriter
    public init(_ dbWriter: any DatabaseWriter) { self.dbWriter = dbWriter }

    public func insert(_ checkIn: CheckIn) throws {
        try dbWriter.write { try checkIn.insert($0) }
    }

    public func update(_ checkIn: CheckIn, now: Int64 = Clock.nowMillis()) throws {
        var c = checkIn
        c.updatedAt = now
        try dbWriter.write { try c.update($0) }
    }

    public func find(id: String) throws -> CheckIn? {
        try dbWriter.read { try CheckIn.fetchOne($0, key: id) }
    }

    public func setParseStatus(id: String, _ status: ParseStatus, now: Int64 = Clock.nowMillis()) throws {
        _ = try dbWriter.write { db in
            try CheckIn
                .filter(Column("id") == id)
                .updateAll(db, Column("parse_status").set(to: status.rawValue), Column("updated_at").set(to: now))
        }
    }

    public func softDelete(id: String, now: Int64 = Clock.nowMillis()) throws {
        _ = try dbWriter.write { db in
            try CheckIn
                .filter(Column("id") == id)
                .updateAll(db, Column("deleted_at").set(to: now), Column("updated_at").set(to: now))
        }
    }
}

// MARK: - Events

public struct EventRepository {
    let dbWriter: any DatabaseWriter
    public init(_ dbWriter: any DatabaseWriter) { self.dbWriter = dbWriter }

    public func insert(_ event: Event) throws {
        try dbWriter.write { try event.insert($0) }
    }

    public func update(_ event: Event, now: Int64 = Clock.nowMillis()) throws {
        var e = event
        e.updatedAt = now
        try dbWriter.write { try e.update($0) }
    }

    public func find(id: String) throws -> Event? {
        try dbWriter.read { try Event.fetchOne($0, key: id) }
    }

    public func softDelete(id: String, now: Int64 = Clock.nowMillis()) throws {
        _ = try dbWriter.write { db in
            try Event
                .filter(Column("id") == id)
                .updateAll(db, Column("deleted_at").set(to: now), Column("updated_at").set(to: now))
        }
    }

    /// The currently open block: a confirmed event with no end time (in progress).
    public func openBlock(userId: String? = nil) throws -> Event? {
        try dbWriter.read { db in
            try Self.liveEvents(userId: userId)
                .filter(Column("state") == EventState.confirmed.rawValue)
                .filter(Column("end_at") == nil)
                .filter(Column("start_at") != nil)
                .order(Column("start_at").desc)
                .fetchOne(db)
        }
    }

    /// Live (non-deleted) planned blocks, ordered by sequence then start.
    public func plannedBlocks(userId: String? = nil) throws -> [Event] {
        try dbWriter.read { db in
            try Self.liveEvents(userId: userId)
                .filter(Column("state") == EventState.planned.rawValue)
                .order(Column("sequence_hint"), Column("start_at"))
                .fetchAll(db)
        }
    }

    /// Events overlapping a local day's `[start, end)` window (DST-safe via LocalDay).
    /// Loose blocks (NULL start) are day-less and excluded here.
    public func events(on day: LocalDay, tz: TimeZone, userId: String? = nil) throws -> [Event] {
        let (start, end) = day.bounds(in: tz)
        return try dbWriter.read { db in
            try Self.liveEvents(userId: userId)
                .filter(Column("start_at") != nil)
                .filter(Column("start_at") < end)
                .filter(Column("end_at") == nil || Column("end_at") > start)
                .order(Column("start_at"))
                .fetchAll(db)
        }
    }

    /// Idempotent import: if a live event with the same (source, source_ref) exists,
    /// return it unchanged; otherwise insert. Guarded also by a unique index.
    @discardableResult
    public func upsertBySourceRef(_ event: Event) throws -> Event {
        try dbWriter.write { db in
            if let ref = event.sourceRef {
                if let existing = try Self.liveEvents(userId: nil)
                    .filter(Column("source") == event.source)
                    .filter(Column("source_ref") == ref)
                    .fetchOne(db) {
                    return existing
                }
            }
            try event.insert(db)
            return event
        }
    }

    /// Confirmed, non-deleted events whose start falls in `[range.lowerBound, range.upperBound)`.
    public func confirmed(in range: Range<Int64>, userId: String? = nil) throws -> [Event] {
        try dbWriter.read { db in
            try Self.liveEvents(userId: userId)
                .filter(Column("state") == EventState.confirmed.rawValue)
                .filter(Column("start_at") != nil)
                .filter(Column("start_at") >= range.lowerBound && Column("start_at") < range.upperBound)
                .order(Column("start_at"))
                .fetchAll(db)
        }
    }

    private static func liveEvents(userId: String?) -> QueryInterfaceRequest<Event> {
        var req = Event.filter(Column("deleted_at") == nil)
        if let userId {
            req = req.filter(Column("user_id") == userId)
        }
        return req
    }
}

// MARK: - Event revisions (audit + undo)

public struct RevisionRepository {
    let dbWriter: any DatabaseWriter
    public init(_ dbWriter: any DatabaseWriter) { self.dbWriter = dbWriter }

    public func append(_ revision: EventRevision) throws {
        try dbWriter.write { try revision.insert($0) }
    }

    /// All revisions in one reconciliation batch, newest first (for unit undo).
    public func byBatch(_ batchId: String) throws -> [EventRevision] {
        try dbWriter.read { db in
            try EventRevision
                .filter(Column("batch_id") == batchId)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }
}
