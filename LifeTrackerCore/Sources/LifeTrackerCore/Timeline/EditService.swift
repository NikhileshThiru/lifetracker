import Foundation
import GRDB

/// Manual edits to events (the editing UI's backend). Like `TimelineService`,
/// every change writes an `event_revisions` row grouped by a `batch_id`, so any
/// single edit undoes as a unit. Each mutating call returns its `batchId`.
public struct EditService {
    let dbWriter: any DatabaseWriter

    public init(_ dbWriter: any DatabaseWriter) { self.dbWriter = dbWriter }

    /// Manually create an event (the typed/manual entry path) with exact times,
    /// recording a `create` revision. Returns the new event.
    @discardableResult
    public func create(
        title: String, categoryId: String?, start: Int64?, end: Int64?,
        state: EventState, userId: String? = nil, source: EventSource = .manual,
        now: Int64 = Clock.nowMillis()
    ) throws -> Event {
        try dbWriter.write { db in
            let ev = Event(
                id: newID(), userId: userId, categoryId: categoryId, title: title, notes: nil,
                startAt: start, endAt: end, state: state.rawValue, sequenceHint: nil,
                confidence: state == .planned ? 0.6 : 1.0, source: source.rawValue, sourceRef: nil,
                originCheckInId: nil, isPinned: false, createdAt: now, updatedAt: now, deletedAt: nil
            )
            try ev.insert(db)
            let batchId = newID()
            let rev = EventRevision(
                id: newID(), eventId: ev.id, checkInId: nil, batchId: batchId,
                changeKind: ChangeKind.create.rawValue, beforeJson: nil, afterJson: Self.encode(ev), createdAt: now
            )
            try rev.insert(db)
            return ev
        }
    }

    @discardableResult
    public func retime(eventId: String, start: Int64?, end: Int64?, now: Int64 = Clock.nowMillis()) throws -> String? {
        try mutate(eventId, kind: .retime, now: now) { ev in
            ev.startAt = start
            ev.endAt = end
        }
    }

    @discardableResult
    public func recategorize(eventId: String, categoryId: String, now: Int64 = Clock.nowMillis()) throws -> String? {
        try mutate(eventId, kind: .recategorize, now: now) { ev in ev.categoryId = categoryId }
    }

    @discardableResult
    public func rename(eventId: String, title: String, now: Int64 = Clock.nowMillis()) throws -> String? {
        try mutate(eventId, kind: .edit, now: now) { ev in ev.title = title }
    }

    @discardableResult
    public func confirm(eventId: String, now: Int64 = Clock.nowMillis()) throws -> String? {
        try mutate(eventId, kind: .confirm, now: now) { ev in
            ev.state = EventState.confirmed.rawValue
            ev.confidence = 1.0
        }
    }

    @discardableResult
    public func delete(eventId: String, now: Int64 = Clock.nowMillis()) throws -> String? {
        try mutate(eventId, kind: .delete, now: now) { ev in ev.deletedAt = now }
    }

    /// Merges block `otherId` into `eventId` (spec §4): the kept block's span
    /// becomes the union of both, the other is soft-deleted — one undoable batch.
    /// If either block is still open (no end), the merged block stays open.
    @discardableResult
    public func merge(eventId: String, absorbing otherId: String, now: Int64 = Clock.nowMillis()) throws -> String? {
        try dbWriter.write { db in
            guard var keep = try Event.fetchOne(db, key: eventId),
                  var other = try Event.fetchOne(db, key: otherId),
                  keep.id != other.id else { return nil }
            let batchId = newID()
            let beforeKeep = Self.encode(keep)
            let beforeOther = Self.encode(other)

            let starts = [keep.startAt, other.startAt].compactMap { $0 }
            keep.startAt = starts.min() ?? keep.startAt
            keep.endAt = (keep.endAt == nil || other.endAt == nil)
                ? nil
                : max(keep.endAt!, other.endAt!)
            if keep.state != EventState.confirmed.rawValue,
               other.state == EventState.confirmed.rawValue {
                keep.state = EventState.confirmed.rawValue
            }
            keep.updatedAt = now
            other.deletedAt = now
            other.updatedAt = now
            try keep.update(db)
            try other.update(db)

            for (id, before, after, kind) in [
                (keep.id, beforeKeep, Self.encode(keep), ChangeKind.merge),
                (other.id, beforeOther, Self.encode(other), ChangeKind.delete),
            ] {
                let rev = EventRevision(
                    id: newID(), eventId: id, checkInId: nil, batchId: batchId,
                    changeKind: kind.rawValue, beforeJson: before, afterJson: after, createdAt: now
                )
                try rev.insert(db)
            }
            return batchId
        }
    }

    /// Splits a block at `splitMs` (strictly inside its span, spec §4): the
    /// original keeps [start, split), a twin gets [split, end) — one undoable batch.
    @discardableResult
    public func split(eventId: String, at splitMs: Int64, now: Int64 = Clock.nowMillis()) throws -> String? {
        try dbWriter.write { db in
            guard var ev = try Event.fetchOne(db, key: eventId),
                  let start = ev.startAt, let end = ev.endAt,
                  splitMs > start, splitMs < end else { return nil }
            let batchId = newID()
            let before = Self.encode(ev)
            ev.endAt = splitMs
            ev.updatedAt = now
            try ev.update(db)

            var twin = ev
            twin.id = newID()
            twin.startAt = splitMs
            twin.endAt = end
            twin.createdAt = now
            twin.updatedAt = now
            try twin.insert(db)

            for (id, b, a, kind) in [
                (ev.id, before, Self.encode(ev), ChangeKind.split),
                (twin.id, nil, Self.encode(twin), ChangeKind.create),
            ] {
                let rev = EventRevision(
                    id: newID(), eventId: id, checkInId: nil, batchId: batchId,
                    changeKind: kind.rawValue, beforeJson: b, afterJson: a, createdAt: now
                )
                try rev.insert(db)
            }
            return batchId
        }
    }

    /// Merges category `sourceId` into `targetId`: repoints every live event
    /// (one revision each, single batch — undoable as a unit) and archives the
    /// source category so it stops matching and disappears from pickers.
    @discardableResult
    public func mergeCategory(sourceId: String, into targetId: String, now: Int64 = Clock.nowMillis()) throws -> String {
        try dbWriter.write { db in
            let batchId = newID()
            let events = try Event
                .filter(Column("deleted_at") == nil)
                .filter(Column("category_id") == sourceId)
                .fetchAll(db)
            for var ev in events {
                let before = Self.encode(ev)
                ev.categoryId = targetId
                ev.updatedAt = now
                try ev.update(db)
                let rev = EventRevision(
                    id: newID(), eventId: ev.id, checkInId: nil, batchId: batchId,
                    changeKind: ChangeKind.recategorize.rawValue,
                    beforeJson: before, afterJson: Self.encode(ev), createdAt: now
                )
                try rev.insert(db)
            }
            if var cat = try Category.fetchOne(db, key: sourceId) {
                cat.isArchived = true
                cat.updatedAt = now
                try cat.update(db)
            }
            return batchId
        }
    }

    /// Reverts every change in a batch to its pre-edit state (unit undo).
    public func undo(batchId: String, now: Int64 = Clock.nowMillis()) throws {
        try dbWriter.write { db in
            let revs = try EventRevision
                .filter(Column("batch_id") == batchId)
                .order(Column("created_at").desc)
                .fetchAll(db)
            for rev in revs {
                if let before = rev.beforeJson,
                   let data = before.data(using: .utf8),
                   var ev = try? JSONDecoder().decode(Event.self, from: data) {
                    ev.updatedAt = now
                    try ev.update(db)                 // restore prior state (incl. un-delete)
                } else if var ev = try Event.fetchOne(db, key: rev.eventId) {
                    ev.deletedAt = now                 // was a create → undo by removing
                    ev.updatedAt = now
                    try ev.update(db)
                }
            }
        }
    }

    private func mutate(_ eventId: String, kind: ChangeKind, now: Int64, _ change: (inout Event) -> Void) throws -> String? {
        try dbWriter.write { db in
            guard var ev = try Event.fetchOne(db, key: eventId) else { return nil }
            let before = Self.encode(ev)
            change(&ev)
            ev.updatedAt = now
            try ev.update(db)
            let batchId = newID()
            let rev = EventRevision(
                id: newID(), eventId: eventId, checkInId: nil, batchId: batchId,
                changeKind: kind.rawValue, beforeJson: before, afterJson: Self.encode(ev), createdAt: now
            )
            try rev.insert(db)
            return batchId
        }
    }

    private static func encode(_ ev: Event) -> String? {
        (try? JSONEncoder().encode(ev)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
