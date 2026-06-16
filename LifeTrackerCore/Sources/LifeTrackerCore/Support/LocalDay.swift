import Foundation

/// A calendar day in a specific timezone. Used to window events into local days.
/// Bounds are computed with `Calendar`, so DST-shortened/-lengthened days are correct.
public struct LocalDay: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local day containing `date` in `tz`.
    public init(containing date: Date, in tz: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.year = c.year!
        self.month = c.month!
        self.day = c.day!
    }

    private func calendar(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    /// Midnight at the start of this local day, in `tz`.
    public func startDate(in tz: TimeZone) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        // Some DST transitions skip midnight; Calendar resolves to the valid instant.
        return calendar(tz).date(from: comps)!
    }

    /// `[startMs, endMs)` epoch-millisecond bounds of this local day in `tz`. DST-safe.
    public func bounds(in tz: TimeZone) -> (startMs: Int64, endMs: Int64) {
        let start = startDate(in: tz)
        let end = calendar(tz).date(byAdding: .day, value: 1, to: start)!
        return (Clock.millis(from: start), Clock.millis(from: end))
    }
}
