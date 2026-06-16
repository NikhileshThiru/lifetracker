import Foundation
import GRDB

/// Outcome of reconciling one check-in. `batchId` groups every revision so the
/// whole reconciliation undoes as a unit.
public struct ReconciliationResult: Sendable, Equatable {
    public let batchId: String
    public let affectedEventIds: [String]
}

/// The deterministic half of the hybrid contract: turns a `ParsedCheckIn`
/// (structure + stated times only) into concrete DB mutations. Owns ALL event
/// writes; the parser never touches the database. Runs in one transaction.
public struct TimelineService {
    let dbWriter: any DatabaseWriter

    public init(_ dbWriter: any DatabaseWriter) { self.dbWriter = dbWriter }

    private static let plannedConfidence = 0.6

    @discardableResult
    public func reconcile(
        _ parsed: ParsedCheckIn,
        now: Int64,
        timeZone: TimeZone,
        userId: String? = nil,
        checkInId: String? = nil
    ) throws -> ReconciliationResult {
        let resolver = TimeResolver(now: now, timeZone: timeZone)
        let batchId = newID()
        var ctx = Context(now: now, userId: userId, checkInId: checkInId, batchId: batchId, resolver: resolver)

        try dbWriter.write { db in
            ctx.nextSeq = (try Self.maxSequenceHint(db, userId: userId) ?? 0) + 1
            // Anchors first: they correct/close existing blocks before new ones land.
            for anchor in parsed.anchors {
                try applyAnchor(anchor, db: db, ctx: &ctx)
            }
            for block in parsed.blocks {
                try applyBlock(block, db: db, ctx: &ctx)
            }
        }
        return ReconciliationResult(batchId: batchId, affectedEventIds: ctx.affected)
    }

    // Mutable per-reconcile state threaded through the helpers.
    private struct Context {
        let now: Int64
        let userId: String?
        let checkInId: String?
        let batchId: String
        let resolver: TimeResolver
        var nextSeq = 1
        var affected: [String] = []
    }

    // MARK: - Blocks

    private func applyBlock(_ block: ParsedBlock, db: Database, ctx: inout Context) throws {
        let categoryId = try resolveCategory(db, name: block.category, kind: block.categoryKind, ctx: ctx)
        let temporal = TemporalState(rawValue: block.temporalState) ?? .planned
        let startPast = block.statedStart.flatMap { ctx.resolver.resolveClock($0, direction: .past) }
        let startFuture = block.statedStart.flatMap { ctx.resolver.resolveClock($0, direction: .future) }
        let endPast = block.statedEnd.flatMap { ctx.resolver.resolveClock($0, direction: .past) }
        let duration = block.statedDuration.flatMap { ctx.resolver.resolveDuration($0) }

        // Closing/finishing an activity → confirm an existing block if we can find one.
        if block.closesOpenBlock || temporal == .completed {
            let target = try openBlock(db, ctx: ctx) ?? recentPlannedMatching(db, title: block.title, categoryId: categoryId, ctx: ctx)
            if var ev = target {
                let before = Self.encode(ev)
                let changedTimes = (endPast != nil && ev.endAt != nil)
                ev.state = EventState.confirmed.rawValue
                ev.endAt = endPast ?? ev.endAt ?? ctx.now
                if ev.startAt == nil { ev.startAt = startPast }
                if ev.categoryId == nil { ev.categoryId = categoryId }
                ev.confidence = 1.0
                ev.updatedAt = ctx.now
                try ev.update(db)
                try record(changedTimes ? .retime : .confirm, before: before, after: Self.encode(ev), eventId: ev.id, db: db, ctx: &ctx)
                return
            }
            // Nothing to match → record the completed activity as a confirmed block.
            let end = endPast ?? ctx.now
            let start = startPast ?? duration.map { end - $0 }
            try insertNew(db: db, ctx: &ctx, categoryId: categoryId, title: block.title,
                          start: start, end: end, state: .confirmed, confidence: 1.0, sequenceHint: nil)
            return
        }

        // In-progress → this becomes the new open block; close any prior open block first.
        if temporal == .inProgress {
            let start = startPast ?? ctx.now
            try closeOpenBlockIfAny(db: db, at: start, ctx: &ctx)
            try insertNew(db: db, ctx: &ctx, categoryId: categoryId, title: block.title,
                          start: start, end: nil, state: .confirmed, confidence: 1.0, sequenceHint: nil)
            return
        }

        // Planned: explicit times pin it; otherwise it's a loose, ordered placeholder.
        var end = block.statedEnd.flatMap { ctx.resolver.resolveClock($0, direction: .future) }
        if end == nil, let startFuture, let duration { end = startFuture + duration }
        let loose = (startFuture == nil)
        let seq: Int? = loose ? ctx.nextSeq : nil
        if loose { ctx.nextSeq += 1 }
        try insertNew(db: db, ctx: &ctx, categoryId: categoryId, title: block.title,
                      start: startFuture, end: end, state: .planned,
                      confidence: Self.plannedConfidence, sequenceHint: seq)
    }

    // MARK: - Anchors

    private func applyAnchor(_ anchor: ParsedAnchor, db: Database, ctx: inout Context) throws {
        let kind = AnchorKind(rawValue: anchor.kind) ?? .retime
        switch kind {
        case .wakeUp:
            // Close the open sleep block at the wake time.
            let end = anchor.relativeReference.flatMap { ctx.resolver.resolveRelative($0) } ?? ctx.now
            if var sleep = try openSleepBlock(db, ctx: ctx) {
                let before = Self.encode(sleep)
                sleep.endAt = end
                sleep.state = EventState.confirmed.rawValue
                sleep.updatedAt = ctx.now
                try sleep.update(db)
                try record(.confirm, before: before, after: Self.encode(sleep), eventId: sleep.id, db: db, ctx: &ctx)
            }

        case .backfillStart:
            let start = anchor.newStart.flatMap { ctx.resolver.resolveClock($0, direction: .past) }
                ?? anchor.relativeReference.flatMap { ctx.resolver.resolveRelative($0) }
            guard let start else { return }
            if var ev = try findTarget(db, hint: anchor.targetHint, ctx: ctx) {
                let before = Self.encode(ev)
                ev.startAt = start
                ev.updatedAt = ctx.now
                try ev.update(db)
                try record(.backfill, before: before, after: Self.encode(ev), eventId: ev.id, db: db, ctx: &ctx)
            }

        case .setEnd:
            let end = anchor.newEnd.flatMap { ctx.resolver.resolveClock($0, direction: .nearest) }
            guard let end else { return }
            if var ev = try findTarget(db, hint: anchor.targetHint, ctx: ctx) {
                let before = Self.encode(ev)
                ev.endAt = end
                ev.updatedAt = ctx.now
                try ev.update(db)
                try record(.retime, before: before, after: Self.encode(ev), eventId: ev.id, db: db, ctx: &ctx)
            }

        case .retime:
            let newStart = anchor.newStart.flatMap { ctx.resolver.resolveClock($0, direction: .nearest) }
            let newEnd = anchor.newEnd.flatMap { ctx.resolver.resolveClock($0, direction: .nearest) }
            guard newStart != nil || newEnd != nil else { return }
            if var ev = try findTarget(db, hint: anchor.targetHint, ctx: ctx) {
                let before = Self.encode(ev)
                if let newStart { ev.startAt = newStart }
                if let newEnd { ev.endAt = newEnd }
                ev.updatedAt = ctx.now
                try ev.update(db)
                try record(.retime, before: before, after: Self.encode(ev), eventId: ev.id, db: db, ctx: &ctx)
            }

        case .skip:
            // Delete a planned block; no-op if none matches.
            if var ev = try findTarget(db, hint: anchor.targetHint, ctx: ctx, plannedOnly: true) {
                let before = Self.encode(ev)
                ev.deletedAt = ctx.now
                ev.updatedAt = ctx.now
                try ev.update(db)
                try record(.skip, before: before, after: Self.encode(ev), eventId: ev.id, db: db, ctx: &ctx)
            }
        }
    }

    // MARK: - Insert / close / revisions

    private func insertNew(
        db: Database, ctx: inout Context, categoryId: String?, title: String,
        start: Int64?, end: Int64?, state: EventState, confidence: Double, sequenceHint: Int?
    ) throws {
        let ev = Event(
            id: newID(), userId: ctx.userId, categoryId: categoryId, title: title, notes: nil,
            startAt: start, endAt: end, state: state.rawValue, sequenceHint: sequenceHint,
            confidence: confidence, source: EventSource.voice.rawValue, sourceRef: nil,
            originCheckInId: ctx.checkInId, isPinned: false,
            createdAt: ctx.now, updatedAt: ctx.now, deletedAt: nil
        )
        try ev.insert(db)
        try record(.create, before: nil, after: Self.encode(ev), eventId: ev.id, db: db, ctx: &ctx)
    }

    private func closeOpenBlockIfAny(db: Database, at end: Int64, ctx: inout Context) throws {
        guard var open = try openBlock(db, ctx: ctx) else { return }
        let before = Self.encode(open)
        open.endAt = end
        open.updatedAt = ctx.now
        try open.update(db)
        try record(.confirm, before: before, after: Self.encode(open), eventId: open.id, db: db, ctx: &ctx)
    }

    private func record(_ kind: ChangeKind, before: String?, after: String?, eventId: String, db: Database, ctx: inout Context) throws {
        let rev = EventRevision(
            id: newID(), eventId: eventId, checkInId: ctx.checkInId, batchId: ctx.batchId,
            changeKind: kind.rawValue, beforeJson: before, afterJson: after, createdAt: ctx.now
        )
        try rev.insert(db)
        if !ctx.affected.contains(eventId) { ctx.affected.append(eventId) }
    }

    // MARK: - Queries (transaction-scoped)

    private func liveEvents(_ db: Database, ctx: Context) -> QueryInterfaceRequest<Event> {
        var req = Event.filter(Column("deleted_at") == nil)
        if let userId = ctx.userId { req = req.filter(Column("user_id") == userId) }
        return req
    }

    private func openBlock(_ db: Database, ctx: Context) throws -> Event? {
        try liveEvents(db, ctx: ctx)
            .filter(Column("state") == EventState.confirmed.rawValue)
            .filter(Column("end_at") == nil)
            .filter(Column("start_at") != nil)
            .order(Column("start_at").desc)
            .fetchOne(db)
    }

    private func plannedBlocks(_ db: Database, ctx: Context) throws -> [Event] {
        try liveEvents(db, ctx: ctx)
            .filter(Column("state") == EventState.planned.rawValue)
            .order(Column("sequence_hint"), Column("start_at"))
            .fetchAll(db)
    }

    private func recentPlannedMatching(_ db: Database, title: String, categoryId: String?, ctx: Context) throws -> Event? {
        let planned = try plannedBlocks(db, ctx: ctx)
        if let byCat = planned.first(where: { $0.categoryId == categoryId }) { return byCat }
        return planned.first(where: { ($0.title).map { CategoryNormalizer.matches($0, title) } ?? false })
    }

    private func openSleepBlock(_ db: Database, ctx: Context) throws -> Event? {
        let openEnded = try liveEvents(db, ctx: ctx)
            .filter(Column("end_at") == nil)
            .order(Column("start_at").desc)
            .fetchAll(db)
        for ev in openEnded {
            if let cid = ev.categoryId, try categoryKind(db, id: cid) == CategoryKind.sleep.rawValue {
                return ev
            }
        }
        return nil
    }

    /// Finds the event an anchor refers to: by title hint, preferring the open
    /// block, then planned, then recent confirmed. With no hint, the open block.
    private func findTarget(_ db: Database, hint: String?, ctx: Context, plannedOnly: Bool = false) throws -> Event? {
        if plannedOnly {
            let planned = try plannedBlocks(db, ctx: ctx)
            guard let hint else { return planned.first }
            return planned.first { ($0.title).map { CategoryNormalizer.matches($0, hint) } ?? false }
        }
        guard let hint else { return try openBlock(db, ctx: ctx) }

        var pool: [Event] = []
        if let open = try openBlock(db, ctx: ctx) { pool.append(open) }
        pool += try plannedBlocks(db, ctx: ctx)
        pool += try liveEvents(db, ctx: ctx)
            .filter(Column("state") == EventState.confirmed.rawValue)
            .order(Column("start_at").desc)
            .limit(5)
            .fetchAll(db)
        return pool.first { ($0.title).map { CategoryNormalizer.matches($0, hint) } ?? false }
    }

    private func categoryKind(_ db: Database, id: String) throws -> String? {
        try Category.fetchOne(db, key: id)?.kind
    }

    private func resolveCategory(_ db: Database, name: String, kind: String, ctx: Context) throws -> String {
        let kindEnum = CategoryKind.parse(kind)
        let existing = try Category
            .filter(Column("deleted_at") == nil)
            .filter(Column("is_archived") == false)
            .fetchAll(db)
        if let hit = existing.first(where: { $0.kind == kindEnum.rawValue && CategoryNormalizer.matches($0.name, name) })
            ?? existing.first(where: { CategoryNormalizer.matches($0.name, name) }) {
            return hit.id
        }
        let created = Category(
            id: newID(), userId: ctx.userId, parentId: nil,
            name: name.trimmingCharacters(in: .whitespaces), kind: kindEnum.rawValue,
            colorHex: CategoryPalette.color(for: kindEnum), icon: CategoryPalette.icon(for: kindEnum),
            isDefault: false, createdBy: "auto",
            sortOrder: (existing.map(\.sortOrder).max() ?? 0) + 1,
            isArchived: false, createdAt: ctx.now, updatedAt: ctx.now, deletedAt: nil
        )
        try created.insert(db)
        return created.id
    }

    private static func maxSequenceHint(_ db: Database, userId: String?) throws -> Int? {
        var req = Event.filter(Column("deleted_at") == nil).filter(Column("sequence_hint") != nil)
        if let userId { req = req.filter(Column("user_id") == userId) }
        return try Int.fetchOne(db, req.select(max(Column("sequence_hint"))))
    }

    static func encode(_ event: Event) -> String? {
        guard let data = try? JSONEncoder().encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
