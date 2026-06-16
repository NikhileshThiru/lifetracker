import Foundation

public enum GapKind: Sendable, Equatable {
    case todo            // a daytime gap to fill (tappable to-do bar)
    case sleepCandidate  // an overnight stretch to confirm as sleep
}

/// A computed (never stored) span of unlogged time within a day.
public struct Gap: Sendable, Equatable {
    public let startAt: Int64
    public let endAt: Int64
    public let kind: GapKind
    public var minutes: Int { Int((endAt - startAt) / 60_000) }
}

/// Computes gaps as the complement of confirmed events across a local day.
/// Gaps are derived for display and never persisted (spec §5).
public enum GapCalculator {
    public static let minGapMinutes = 15
    public static let sleepMinHours = 3

    public static func gaps(events: [Event], day: LocalDay, timeZone: TimeZone, now: Int64) -> [Gap] {
        let (dayStart, dayEnd) = day.bounds(in: timeZone)
        if now < dayStart { return [] }              // future day → nothing to fill yet
        let effEnd = min(dayEnd, now)                 // don't treat the future as a gap
        guard effEnd > dayStart else { return [] }

        // Covered intervals from confirmed events, clipped to [dayStart, effEnd].
        var intervals: [(Int64, Int64)] = []
        for e in events where e.deletedAt == nil
            && e.state == EventState.confirmed.rawValue
            && e.startAt != nil {
            let s = max(e.startAt!, dayStart)
            let rawEnd = e.endAt ?? effEnd            // open block → up to now
            let en = min(rawEnd, effEnd)
            if s < en { intervals.append((s, en)) }
        }
        intervals.sort { $0.0 < $1.0 }

        var merged: [(Int64, Int64)] = []
        for seg in intervals {
            if !merged.isEmpty, seg.0 <= merged[merged.count - 1].1 {
                merged[merged.count - 1].1 = max(merged[merged.count - 1].1, seg.1)
            } else {
                merged.append(seg)
            }
        }

        var gaps: [Gap] = []
        var cursor = dayStart
        for (s, en) in merged {
            if s > cursor { appendGap(from: cursor, to: s, dayStart: dayStart, tz: timeZone, into: &gaps) }
            cursor = max(cursor, en)
        }
        if cursor < effEnd { appendGap(from: cursor, to: effEnd, dayStart: dayStart, tz: timeZone, into: &gaps) }
        return gaps
    }

    private static func appendGap(from g0: Int64, to g1: Int64, dayStart: Int64, tz: TimeZone, into gaps: inout [Gap]) {
        let minutes = Int((g1 - g0) / 60_000)
        if minutes < minGapMinutes { return }        // <15min absorbed into the prior block
        gaps.append(Gap(startAt: g0, endAt: g1, kind: classify(g0, g1, dayStart: dayStart, tz: tz)))
    }

    private static func classify(_ g0: Int64, _ g1: Int64, dayStart: Int64, tz: TimeZone) -> GapKind {
        let hours = Double(g1 - g0) / 3_600_000
        let startHour = localHour(g0, tz: tz)
        let overnight = (g0 == dayStart) || startHour >= 21 || startHour <= 6
        return (hours >= Double(sleepMinHours) && overnight) ? .sleepCandidate : .todo
    }

    private static func localHour(_ ms: Int64, tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.component(.hour, from: Clock.date(fromMillis: ms))
    }
}
