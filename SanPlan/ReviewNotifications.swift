import Foundation
import UserNotifications

/// Shows ARNA's notifications while the app is open and opens the day review when its reminder is tapped.
/// Owned by the coordinator; the review screen itself belongs to «Сегодня и Итоги».
@MainActor
public final class ReviewNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    public static let shared = ReviewNotifications()

    /// Grows by one on every tap on the day-review reminder; TodayScreen opens the review on change.
    @Published public private(set) var dayReviewRequests = 0

    private var installed = false

    public func install(center: UNUserNotificationCenter = .current()) {
        guard !installed else { return }
        installed = true
        center.delegate = self
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        await MainActor.run {
            if identifier == ReviewReminder.identifier { self.dayReviewRequests += 1 }
        }
    }
}
