import Foundation
import LifeTrackerCore

enum TimeFormat {
    /// "3:30 PM" in the given timezone.
    static func clock(_ ms: Int64, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: Clock.date(fromMillis: ms))
    }

    /// "2h 15m" / "45m".
    static func duration(_ ms: Int64) -> String {
        let total = max(0, Int(ms / 60_000))
        let h = total / 60, m = total % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// "Tuesday, Jun 16".
    static func dayTitle(_ ms: Int64, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: Clock.date(fromMillis: ms))
    }
}
