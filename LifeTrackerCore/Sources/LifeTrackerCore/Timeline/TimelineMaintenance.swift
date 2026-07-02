import Foundation
import GRDB

extension TimelineService {
    /// Closes confirmed blocks left open ("in progress") on a previous day.
    /// Nothing runs across days unnoticed: the block gets a modest default
    /// length (1h, clipped to its own day) at lowered confidence, with a
    /// revision, so it reads as an editable guess instead of extending to now
    /// forever. Open sleep blocks from the last 18h are spared — the wake-up
    /// anchor is responsible for those.
    @discardableResult
    public func closeStaleOpenBlocks(asOf now: Int64, timeZone: TimeZone, userId: String? = nil) throws -> [String] {
        let todayStart = Clock.millis(
            from: LocalDay(containing: Clock.date(fromMillis: now), in: timeZone).startDate(in: timeZone)
        )
        let batchId = newID()
        var closed: [String] = []

        try dbWriter.write { db in
            let sleepIds = try Category
                .filter(Column("deleted_at") == nil)
                .filter(Column("kind") == CategoryKind.sleep.rawValue)
                .fetchAll(db)
                .map(\.id)

            var req = Event
                .filter(Column("deleted_at") == nil)
                .filter(Column("state") == EventState.confirmed.rawValue)
                .filter(Column("end_at") == nil)
                .filter(Column("start_at") != nil && Column("start_at") < todayStart)
            if let userId { req = req.filter(Column("user_id") == userId) }

            for var ev in try req.fetchAll(db) {
                guard let start = ev.startAt else { continue }
                if let cid = ev.categoryId, sleepIds.contains(cid), start >= now - 18 * 3_600_000 {
                    continue   // plausibly last night's sleep — wake-up will close it
                }
                let dayEnd = LocalDay(containing: Clock.date(fromMillis: start), in: timeZone)
                    .bounds(in: timeZone).endMs
                let before = TimelineService.encode(ev)
                ev.endAt = min(start + 3_600_000, dayEnd)
                ev.confidence = TimelineService.inferredConfidence
                ev.updatedAt = now
                try ev.update(db)
                let rev = EventRevision(
                    id: newID(), eventId: ev.id, checkInId: nil, batchId: batchId,
                    changeKind: ChangeKind.confirm.rawValue,
                    beforeJson: before, afterJson: TimelineService.encode(ev), createdAt: now
                )
                try rev.insert(db)
                closed.append(ev.id)
            }
        }
        return closed
    }

    /// Daily rollover: expire planned blocks from previous days that were never
    /// confirmed (spec §5). Soft-deletes them and records a revision so the
    /// rollover is auditable/undoable. Returns the expired event ids.
    @discardableResult
    public func expireStalePlanned(asOf now: Int64, timeZone: TimeZone, userId: String? = nil) throws -> [String] {
        let todayStart = LocalDay(containing: Clock.date(fromMillis: now), in: timeZone).startDate(in: timeZone)
        let cutoff = Clock.millis(from: todayStart)
        let batchId = newID()
        var expired: [String] = []

        try dbWriter.write { db in
            var req = Event
                .filter(Column("deleted_at") == nil)
                .filter(Column("state") == EventState.planned.rawValue)
            if let userId { req = req.filter(Column("user_id") == userId) }

            for var ev in try req.fetchAll(db) {
                // Pinned blocks scheduled for a past day, or loose placeholders
                // created before today, are stale.
                let stale = ev.startAt.map { $0 < cutoff } ?? (ev.createdAt < cutoff)
                guard stale else { continue }

                let before = TimelineService.encode(ev)
                ev.deletedAt = now
                ev.updatedAt = now
                try ev.update(db)
                let rev = EventRevision(
                    id: newID(), eventId: ev.id, checkInId: nil, batchId: batchId,
                    changeKind: ChangeKind.delete.rawValue, beforeJson: before, afterJson: nil, createdAt: now
                )
                try rev.insert(db)
                expired.append(ev.id)
            }
        }
        return expired
    }
}
