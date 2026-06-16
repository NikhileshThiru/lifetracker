import Foundation

/// Time helpers. The whole app stores time as epoch milliseconds in UTC and
/// resolves local-day boundaries with the relevant day's IANA timezone.
public enum Clock {
    /// Current time as epoch milliseconds (UTC).
    public static func nowMillis() -> Int64 {
        millis(from: Date())
    }

    /// Epoch milliseconds (UTC) for a `Date`.
    public static func millis(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// `Date` from epoch milliseconds (UTC).
    public static func date(fromMillis ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}

/// A fresh lowercase UUID string, used for every primary key (sync-ready, on-device generated).
public func newID() -> String {
    UUID().uuidString.lowercased()
}
