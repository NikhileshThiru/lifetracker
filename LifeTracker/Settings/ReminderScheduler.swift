import Foundation
import UserNotifications

/// Inactivity nudge ("what's going on?") via local notifications — free, no paid
/// push entitlement. Not a fixed daily alarm: it fires only when you've gone quiet
/// for `idleHours`, and is rescheduled every time you log something. We don't nudge
/// overnight.
enum ReminderScheduler {
    static let identifier = "idle-checkin"
    private static let quietStartHour = 22   // 10pm
    private static let quietEndHour = 8       // 8am

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Replaces any pending nudge with one scheduled for `idleHours` after the last
    /// activity (or soon, if already overdue), shifted out of quiet hours.
    static func reschedule(enabled: Bool, idleHours: Int, lastActivity: Int64?, now: Int64, timeZone: TimeZone) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard enabled else { return }

        let base = lastActivity ?? now
        var fireAt = base + Int64(idleHours) * 3_600_000
        if fireAt <= now + 30_000 { fireAt = now + 60_000 }   // already quiet → nudge ~1 min
        fireAt = shiftedOutOfQuietHours(fireAt, timeZone: timeZone)

        let interval = max(60, Double(fireAt - now) / 1000)
        let content = UNMutableNotificationContent()
        content.title = "What's going on?"
        content.body = "You haven't checked in for a while — tap to log what you're up to."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// If `ms` lands in the overnight quiet window, push it to the next 8am.
    static func shiftedOutOfQuietHours(_ ms: Int64, timeZone: TimeZone) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let hour = cal.component(.hour, from: date)
        guard hour >= quietStartHour || hour < quietEndHour else { return ms }
        // Move to 8am: same day if before 8am, else next day.
        let dayAnchor = hour < quietEndHour ? date : (cal.date(byAdding: .day, value: 1, to: date) ?? date)
        if let eight = cal.date(bySettingHour: quietEndHour, minute: 0, second: 0, of: dayAnchor) {
            return Int64(eight.timeIntervalSince1970 * 1000)
        }
        return ms
    }
}
