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
    /// Confidence for confirmed blocks whose times were inferred (chained/split),
    /// so the UI can hint they're editable guesses.
    private static let inferredConfidence = 0.8
    /// Default length for a completed activity with no time information at all.
    private static let defaultChainBlockMs: Int64 = 30 * 60_000
    /// How far back "start where the timeline left off" may reach.
    private static let chainFallbackWindowMs: Int64 = 12 * 3_600_000
    /// Plausible overnight sleep span for the wake-up anchor.
    private static let minSleepMs: Int64 = 2 * 3_600_000
    private static let maxSleepMs: Int64 = 16 * 3_600_000

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
            try applyBlocks(parsed.blocks, db: db, ctx: &ctx)
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

    /// A completed activity that matched nothing in the DB and awaits chain layout.
    private struct PendingCompleted {
        let block: ParsedBlock
        let categoryId: String?
        let start: Int64?     // resolved stated start
        let end: Int64?       // resolved stated end
        let duration: Int64?  // resolved stated duration
    }

    /// Applies one check-in's blocks as a group. Completed activities that match
    /// an open/planned block confirm it in place; the unmatched rest are laid out
    /// as a *sequential chain* (each ends where the next starts) instead of all
    /// piling up at `now`.
    private func applyBlocks(_ blocks: [ParsedBlock], db: Database, ctx: inout Context) throws {
        var completed: [ParsedBlock] = []
        var inProgress: [ParsedBlock] = []
        var planned: [ParsedBlock] = []
        for b in blocks {
            switch TemporalState.parse(b.temporalState) {
            case .completed: completed.append(b)
            case .inProgress: inProgress.append(b)
            case .planned: planned.append(b)
            }
        }

        // Completed: confirm a matching open/planned block; queue the rest.
        var pending: [PendingCompleted] = []
        var wantsOpenClosed = false
        for block in completed {
            let categoryId = try resolveCategory(db, name: block.category, kind: block.categoryKind, ctx: ctx)
            let start = block.statedStart.flatMap { ctx.resolver.resolveClock($0, direction: .past) }
            let end = block.statedEnd.flatMap { ctx.resolver.resolveClock($0, direction: .past) }
            let duration = block.statedDuration.flatMap { ctx.resolver.resolveDuration($0) }
            if block.closesOpenBlock { wantsOpenClosed = true }

            if var ev = try matchExisting(db, title: block.title, categoryId: categoryId, ctx: ctx) {
                let before = Self.encode(ev)
                let changedTimes = (end != nil && ev.endAt != nil)
                ev.state = EventState.confirmed.rawValue
                if ev.startAt == nil { ev.startAt = start }
                let resolvedEnd = end
                    ?? ev.endAt
                    ?? (ev.startAt).flatMap { s in duration.map { s + $0 } }
                    ?? ctx.now
                ev.endAt = resolvedEnd
                var inferredStart = false
                if ev.startAt == nil {   // was a loose placeholder with nothing stated
                    ev.startAt = resolvedEnd - (duration ?? Self.defaultChainBlockMs)
                    inferredStart = duration == nil
                }
                if ev.categoryId == nil { ev.categoryId = categoryId }
                ev.confidence = inferredStart ? Self.inferredConfidence : 1.0
                ev.updatedAt = ctx.now
                try ev.update(db)
                try record(changedTimes ? .retime : .confirm, before: before, after: Self.encode(ev), eventId: ev.id, db: db, ctx: &ctx)
            } else {
                pending.append(PendingCompleted(block: block, categoryId: categoryId, start: start, end: end, duration: duration))
            }
        }

        // In-progress starts bound the chain's end ("finished X and Y, been cooking since 7").
        let inProgressStarts = inProgress.map { b in
            b.statedStart.flatMap { ctx.resolver.resolveClock($0, direction: .past) } ?? ctx.now
        }

        if !pending.isEmpty {
            let wEnd = pending.last?.end ?? inProgressStarts.first ?? ctx.now
            try layOutChain(pending, wEnd: wEnd, closeOpen: wantsOpenClosed, db: db, ctx: &ctx)
        }

        // In-progress → becomes the new open block; close any prior open block first.
        for (i, block) in inProgress.enumerated() {
            let categoryId = try resolveCategory(db, name: block.category, kind: block.categoryKind, ctx: ctx)
            let start = inProgressStarts[i]
            try closeOpenBlockIfAny(db: db, at: start, ctx: &ctx)
            try insertNew(db: db, ctx: &ctx, categoryId: categoryId, title: block.title,
                          start: start, end: nil, state: .confirmed, confidence: 1.0, sequenceHint: nil)
        }

        // Planned: explicit times pin it; otherwise it's a loose, ordered placeholder.
        for block in planned {
            let categoryId = try resolveCategory(db, name: block.category, kind: block.categoryKind, ctx: ctx)
            let startFuture = block.statedStart.flatMap { ctx.resolver.resolveClock($0, direction: .future) }
            let duration = block.statedDuration.flatMap { ctx.resolver.resolveDuration($0) }
            var end = block.statedEnd.flatMap { ctx.resolver.resolveClock($0, direction: .future) }
            if end == nil, let startFuture, let duration { end = startFuture + duration }
            let loose = (startFuture == nil)
            let seq: Int? = loose ? ctx.nextSeq : nil
            if loose { ctx.nextSeq += 1 }
            try insertNew(db: db, ctx: &ctx, categoryId: categoryId, title: block.title,
                          start: startFuture, end: end, state: .planned,
                          confidence: Self.plannedConfidence, sequenceHint: seq)
        }
    }

    /// The block an unmatched "finished X" should confirm, if any: the open block
    /// when its title/category actually corresponds to X (never blindly — closing
    /// "class" because the speaker finished "lunch" both loses lunch and corrupts
    /// class), else the best-matching planned block (title first, then category).
    private func matchExisting(_ db: Database, title: String, categoryId: String?, ctx: Context) throws -> Event? {
        if let open = try openBlock(db, ctx: ctx) {
            let titleHit = (open.title).map { CategoryNormalizer.titleMatches($0, title) } ?? false
            let categoryHit = open.categoryId != nil && open.categoryId == categoryId
            if titleHit || categoryHit { return open }
        }
        let planned = try plannedBlocks(db, ctx: ctx)
        if let byTitle = planned.first(where: { ($0.title).map { CategoryNormalizer.titleMatches($0, title) } ?? false }) {
            return byTitle
        }
        return planned.first(where: { $0.categoryId != nil && $0.categoryId == categoryId })
    }

    /// Lays out unmatched completed blocks as one contiguous run ending at `wEnd`.
    /// Boundaries come from stated times, then stated durations, then "where the
    /// timeline left off", then an even split — never "everything ends at now".
    private func layOutChain(_ pending: [PendingCompleted], wEnd: Int64, closeOpen: Bool, db: Database, ctx: inout Context) throws {
        let n = pending.count
        var bounds = [Int64?](repeating: nil, count: n + 1)
        var synthetic = [Bool](repeating: false, count: n + 1)

        // 1. Stated boundaries.
        bounds[0] = pending[0].start
        for i in 0..<n {
            if let e = pending[i].end { bounds[i + 1] = e }
            else if i + 1 < n, let s = pending[i + 1].start { bounds[i + 1] = s }
        }

        // 2. Stated durations off known boundaries (before and after defaulting
        //    the chain end, so "from 2 for three hours" ends at 5, not at now).
        func propagateDurations() {
            for i in 0..<n where bounds[i + 1] == nil {
                if let b = bounds[i], let d = pending[i].duration { bounds[i + 1] = b + d }
            }
            for i in (0..<n).reversed() where bounds[i] == nil {
                if let b = bounds[i + 1], let d = pending[i].duration { bounds[i] = b - d }
            }
        }
        propagateDurations()
        if bounds[n] == nil { bounds[n] = wEnd }
        propagateDurations()

        // 3. No stated opening → start where the timeline left off: an unmatched
        //    open block splits its window with the chain; otherwise the most
        //    recent confirmed end (if recent enough).
        let open = try openBlock(db, ctx: ctx)
        if bounds[0] == nil {
            if let open, let openStart = open.startAt, openStart < bounds[n]! {
                bounds[0] = openStart + (bounds[n]! - openStart) / Int64(n + 1)
                synthetic[0] = true
            } else if let lastEnd = try lastConfirmedEnd(db, before: bounds[n]!, ctx: ctx),
                      bounds[n]! - lastEnd <= Self.chainFallbackWindowMs, lastEnd < bounds[n]! {
                bounds[0] = lastEnd
                synthetic[0] = true
            }
        }

        // 4. Remaining unknowns: even split between known neighbours; a leading
        //    run with no anchor at all defaults to 30 minutes per block.
        var i = 0
        while i <= n {
            guard bounds[i] == nil else { i += 1; continue }
            var k = i
            while k <= n, bounds[k] == nil { k += 1 }   // next known bound (bounds[n] is set)
            if i == 0 {
                for t in stride(from: k - 1, through: 0, by: -1) {
                    bounds[t] = bounds[t + 1]! - (pending[t].duration ?? Self.defaultChainBlockMs)
                    synthetic[t] = true
                }
            } else {
                let a = bounds[i - 1]!, b = bounds[k]!
                let steps = Int64(k - i + 1)
                let span = max(0, b - a)
                for t in i..<k {
                    bounds[t] = a + span * Int64(t - i + 1) / steps
                    synthetic[t] = true
                }
            }
            i = k
        }

        // Stated times can be contradictory; keep the chain monotonic.
        for t in 1...n where bounds[t]! < bounds[t - 1]! { bounds[t] = bounds[t - 1]! }

        // A linear timeline can't have something "still running" underneath what
        // was just recounted — close the open block where the chain begins.
        if open != nil, closeOpen || bounds[0]! < ctx.now {
            try closeOpenBlockIfAny(db: db, at: bounds[0]!, ctx: &ctx)
        }

        for (idx, p) in pending.enumerated() {
            let inferred = synthetic[idx] || synthetic[idx + 1]
            try insertNew(db: db, ctx: &ctx, categoryId: p.categoryId, title: p.block.title,
                          start: bounds[idx]!, end: bounds[idx + 1]!, state: .confirmed,
                          confidence: inferred ? Self.inferredConfidence : 1.0, sequenceHint: nil)
        }
    }

    /// Most recent confirmed end at/before `limit` (where the timeline left off).
    private func lastConfirmedEnd(_ db: Database, before limit: Int64, ctx: Context) throws -> Int64? {
        var req = Event
            .filter(Column("deleted_at") == nil)
            .filter(Column("state") == EventState.confirmed.rawValue)
            .filter(Column("end_at") != nil && Column("end_at") <= limit)
        if let userId = ctx.userId { req = req.filter(Column("user_id") == userId) }
        return try Int64.fetchOne(db, req.select(max(Column("end_at"))))
    }

    // MARK: - Anchors

    private func applyAnchor(_ anchor: ParsedAnchor, db: Database, ctx: inout Context) throws {
        guard let kind = AnchorKind.parse(anchor.kind) else { return }
        switch kind {
        case .wakeUp:
            // Close the open sleep block at the wake time — or, in the usual case
            // where no sleep block was ever opened, create the overnight block
            // back to bedtime (where the timeline last left off).
            let end = anchor.relativeReference.flatMap { ctx.resolver.resolveRelative($0) }
                ?? anchor.newEnd.flatMap { ctx.resolver.resolveClock($0, direction: .past) }
                ?? ctx.now
            if var sleep = try openSleepBlock(db, ctx: ctx) {
                let before = Self.encode(sleep)
                sleep.endAt = end
                sleep.state = EventState.confirmed.rawValue
                sleep.updatedAt = ctx.now
                try sleep.update(db)
                try record(.confirm, before: before, after: Self.encode(sleep), eventId: sleep.id, db: db, ctx: &ctx)
            } else if let bedtime = try lastConfirmedEnd(db, before: end - Self.minSleepMs, ctx: ctx),
                      end - bedtime <= Self.maxSleepMs {
                let sleepCategory = try resolveCategory(db, name: "Sleep", kind: CategoryKind.sleep.rawValue, ctx: ctx)
                try insertNew(db: db, ctx: &ctx, categoryId: sleepCategory, title: "Sleep",
                              start: bedtime, end: end, state: .confirmed,
                              confidence: Self.inferredConfidence, sequenceHint: nil)
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
        open.endAt = max(end, open.startAt ?? end)   // never close before it started
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
    /// block, then planned, then recent confirmed. With no hint, the open block —
    /// except for skip, where guessing would delete an arbitrary planned block.
    private func findTarget(_ db: Database, hint: String?, ctx: Context, plannedOnly: Bool = false) throws -> Event? {
        if plannedOnly {
            guard let hint else { return nil }   // "skipped it" with no target → no-op
            let planned = try plannedBlocks(db, ctx: ctx)
            return planned.first { ($0.title).map { CategoryNormalizer.titleMatches($0, hint) } ?? false }
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
        return pool.first { ($0.title).map { CategoryNormalizer.titleMatches($0, hint) } ?? false }
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
