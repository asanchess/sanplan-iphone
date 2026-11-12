import Foundation
import UserNotifications

/// Ежедневное локальное напоминание «Итоги дня». Текст нейтральный: без личных данных и призывов.
public enum ReviewReminder {
    public static let identifier = "arna.review.day"

    /// Fires every day at the chosen local time.
    public static func trigger(for settings: ReviewReminderSettings) -> UNCalendarNotificationTrigger {
        var components = DateComponents()
        components.hour = settings.hour
        components.minute = settings.minute
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
    }

    public static func request(for settings: ReviewReminderSettings) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Итоги дня"
        content.body = "Меньше минуты: настроение и одна строка."
        content.sound = .default
        content.threadIdentifier = identifier
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger(for: settings))
    }

    /// Replaces the scheduled reminder with the one the settings describe, or removes it when switched off.
    /// Returns false when the person has not allowed notifications, so the screen can say so.
    @discardableResult
    public static func apply(_ settings: ReviewReminderSettings, center: UNUserNotificationCenter = .current()) async -> Bool {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard settings.enabled else { return true }
        let allowed: Bool
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: allowed = true
        case .notDetermined: allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: allowed = false
        }
        guard allowed else { return false }
        do {
            try await center.add(request(for: settings))
            return true
        } catch {
            return false
        }
    }

    /// Signing out removes the reminder with the account's data.
    public static func cancel(center: UNUserNotificationCenter = .current()) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
