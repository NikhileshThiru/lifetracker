import Foundation

/// Which direction to prefer when a stated clock time is ambiguous (no AM/PM).
public enum ClockDirection: Sendable {
    case past      // prefer the most recent occurrence at/before now (completed events)
    case future    // prefer the soonest occurrence at/after now (planned events)
    case nearest   // prefer the occurrence closest to now
}

/// Deterministically resolves the parser's *stated* times (clock times,
/// durations, relative references) into absolute epoch-ms, using the injected
/// `now` + timezone. This is the precise half of the hybrid contract — all the
/// clock math the on-device model must NOT do.
public struct TimeResolver: Sendable {
    public let now: Int64
    public let timeZone: TimeZone

    public init(now: Int64, timeZone: TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }

    // MARK: Clock times

    /// Resolves a stated clock time ("3:30", "3:30pm", "15:30", "7") to an
    /// absolute epoch-ms near `now`, disambiguating AM/PM via `direction`.
    public func resolveClock(_ stated: String, direction: ClockDirection = .nearest) -> Int64? {
        guard let parts = Self.parseClock(stated) else { return nil }

        // Candidate 24-hour hours to try.
        var hours: [Int] = []
        var ambiguous = false
        if parts.meridiem != nil {
            hours = [Self.to24(hour12: parts.hour, isPM: parts.meridiem == .pm)]
        } else if parts.hour >= 13 || parts.hour == 0 {
            hours = [parts.hour] // already unambiguous 24h
        } else {
            // Ambiguous: try both AM and PM interpretations.
            ambiguous = true
            let am = parts.hour == 12 ? 0 : parts.hour
            let pm = parts.hour == 12 ? 12 : parts.hour + 12
            hours = [am, pm]
        }

        var candidates: [(ms: Int64, hour: Int)] = []
        for h in hours {
            for dayOffset in [-1, 0, 1] {
                candidates.append((epoch(hour: h, minute: parts.minute, dayOffset: dayOffset), h))
            }
        }
        return pick(candidates, direction: direction, ambiguous: ambiguous)
    }

    // MARK: Durations

    /// Parses a duration phrase ("2 hours", "45 minutes", "1.5 hours", "1h30m",
    /// "an hour", "half an hour") into milliseconds.
    public func resolveDuration(_ stated: String) -> Int64? {
        var s = stated.lowercased()
        s = s.replacingOccurrences(of: "half an hour", with: "30 minutes")
        s = s.replacingOccurrences(of: "half hour", with: "30 minutes")
        s = s.replacingOccurrences(of: "an hour", with: "1 hour")
        s = s.replacingOccurrences(of: "a hour", with: "1 hour")

        var millis: Int64 = 0
        var matched = false
        if let hStr = Self.firstGroup(#"(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)(?![a-zA-Z])"#, in: s),
           let hours = Double(hStr) {
            millis += Int64((hours * 3600 * 1000).rounded())
            matched = true
        }
        if let mStr = Self.firstGroup(#"(\d+)\s*(?:m|min|mins|minute|minutes)(?![a-zA-Z])"#, in: s),
           let minutes = Int64(mStr) {
            millis += minutes * 60 * 1000
            matched = true
        }
        return matched ? millis : nil
    }

    // MARK: Relative references

    /// Resolves a relative reference ("an hour ago", "20 minutes ago",
    /// "since 2pm", "just now") to an absolute epoch-ms.
    public func resolveRelative(_ stated: String) -> Int64? {
        let s = stated.lowercased().trimmingCharacters(in: .whitespaces)

        if s.contains("just") || s == "now" || s.contains("right now") {
            return now
        }
        if s.contains("ago") {
            var part = s.replacingOccurrences(of: "ago", with: " ")
            part = Self.replaceWord("an", with: "1", in: part)
            part = Self.replaceWord("a", with: "1", in: part)
            if let dur = resolveDuration(part) { return now - dur }
        }
        if let range = s.range(of: "since") {
            let part = String(s[range.upperBound...])
            return resolveClock(part, direction: .past)
        }
        return nil
    }

    // MARK: - Internals

    private enum Meridiem { case am, pm }
    private struct ClockParts { var hour: Int; var minute: Int; var meridiem: Meridiem? }

    private static func to24(hour12: Int, isPM: Bool) -> Int {
        if isPM { return hour12 == 12 ? 12 : hour12 + 12 }
        return hour12 == 12 ? 0 : hour12
    }

    private static func parseClock(_ stated: String) -> ClockParts? {
        let s = stated.lowercased()
        if s.contains("noon") { return ClockParts(hour: 12, minute: 0, meridiem: .pm) }
        if s.contains("midnight") { return ClockParts(hour: 12, minute: 0, meridiem: .am) }
        var meridiem: Meridiem?
        if let m = firstGroup(#"([ap])\.?m\.?"#, in: s) {
            meridiem = (m == "p") ? .pm : .am
        }
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,2})(?::(\d{2}))?"#) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = re.firstMatch(in: s, range: range) else { return nil }
        guard let hRange = Range(match.range(at: 1), in: s), let hour = Int(s[hRange]) else { return nil }
        var minute = 0
        if let mRange = Range(match.range(at: 2), in: s), let m = Int(s[mRange]) { minute = m }
        guard hour >= 0, hour <= 23, minute >= 0, minute <= 59 else { return nil }
        return ClockParts(hour: hour, minute: minute, meridiem: meridiem)
    }

    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    private func epoch(hour: Int, minute: Int, dayOffset: Int) -> Int64 {
        let cal = calendar()
        let base = LocalDay(containing: Clock.date(fromMillis: now), in: timeZone).startDate(in: timeZone)
        let day = cal.date(byAdding: .day, value: dayOffset, to: base) ?? base
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let dt = cal.date(from: comps) ?? day
        return Clock.millis(from: dt)
    }

    private func pick(_ candidates: [(ms: Int64, hour: Int)], direction: ClockDirection, ambiguous: Bool) -> Int64? {
        guard !candidates.isEmpty else { return nil }
        let all = candidates.map(\.ms)
        let nearest = { (cs: [Int64]) -> Int64? in
            cs.min(by: { abs($0 - self.now) < abs($1 - self.now) })
        }
        // When the speaker didn't disambiguate AM/PM, prefer readings landing in
        // waking hours (07:00–23:59): a planned "at 3" means 3 PM, never 3 AM
        // tomorrow. Past stays unbiased — "went to bed at 2" must resolve to the
        // most recent 2 AM, and most-recent-past already behaves well.
        let waking = candidates.filter { $0.hour >= 7 }.map(\.ms)
        let pool = (ambiguous && !waking.isEmpty) ? waking : all

        switch direction {
        case .future:
            return pool.filter { $0 >= now }.min()
                ?? all.filter { $0 >= now }.min()
                ?? nearest(all)
        case .past:
            return all.filter { $0 <= now }.max() ?? nearest(all)
        case .nearest:
            return nearest(pool) ?? nearest(all)
        }
    }

    // MARK: Regex helpers

    private static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func replaceWord(_ word: String, with replacement: String, in s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\b\(word)\\b", options: [.caseInsensitive]) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: replacement)
    }
}
