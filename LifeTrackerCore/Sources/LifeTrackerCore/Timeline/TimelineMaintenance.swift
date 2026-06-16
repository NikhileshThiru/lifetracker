import Foundation
import GRDB

extension TimelineService {
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
