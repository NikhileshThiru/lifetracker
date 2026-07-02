import Foundation

/// Per-day time attribution for events, including ones that cross midnight.
/// Each local day should show and count only the slice of an event that falls
/// within that day — otherwise an overnight block double-counts on both days.
public extension Event {
    /// How this event overlaps the window `[windowStart, windowEnd)`, clipping an
    /// open block (`endAt == nil`) at `now`. Returns nil for loose blocks (no start)
    /// or when the event doesn't intersect the window.
    func clip(to windowStart: Int64, _ windowEnd: Int64, now: Int64) -> (start: Int64, end: Int64)? {
        guard let s = startAt else { return nil }
        let e = endAt ?? now
        let lo = max(s, windowStart)
        let hi = min(e, windowEnd)
        return hi > lo ? (lo, hi) : nil
    }

    /// Minutes of this event that fall within `[windowStart, windowEnd)`
    /// (open blocks clipped at `now`). Zero if it doesn't intersect.
    func minutes(in windowStart: Int64, _ windowEnd: Int64, now: Int64) -> Int {
        guard let (lo, hi) = clip(to: windowStart, windowEnd, now: now) else { return 0 }
        return Int((hi - lo) / 60_000)
    }

    /// True if this event's real start is before the window (it began on a prior day).
    func continuesBefore(_ windowStart: Int64) -> Bool {
        guard let s = startAt else { return false }
        return s < windowStart
    }

    /// True if this event's real end is after the window, or it's still open past it
    /// (it spills into a later day). Open blocks are measured against `now`.
    func continuesAfter(_ windowEnd: Int64, now: Int64) -> Bool {
        guard startAt != nil else { return false }
        let e = endAt ?? now
        return e > windowEnd
    }
}
