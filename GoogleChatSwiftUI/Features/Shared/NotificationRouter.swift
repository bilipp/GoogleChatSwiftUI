import AppKit
import Observation
import UserNotifications

/// Turns a clicked notification into a conversation to open.
///
/// Separate from `NotificationService`, which posts them. Three constraints force it
/// to be its own long-lived object rather than a method on the session model:
/// `UNUserNotificationCenter` holds its delegate weakly, the delegate has to be
/// installed before the app finishes launching, and that moment is well before
/// sign-in has restored and a session model exists.
@MainActor
@Observable
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Space the user asked for, held until the sidebar claims it.
    ///
    /// Buffered rather than delivered straight to the UI because a click can arrive
    /// before there is any UI to deliver it to: clicking a notification for a quit
    /// app launches it, and the delegate fires while auth is still restoring.
    private(set) var pendingSpaceName: String?

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Takes the pending space and clears it, so a click opens a conversation once.
    func claimPendingSpace() -> String? {
        defer { pendingSpaceName = nil }
        return pendingSpaceName
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Read out here: `UNNotificationResponse` is not Sendable, but the one value
        // needed from it is.
        guard let spaceName = response.notification.request.content
            .userInfo["spaceName"] as? String
        else { return }

        await MainActor.run {
            pendingSpaceName = spaceName
            activateWindow()
        }
    }

    /// Keeps a notification that lands while the app is frontmost.
    ///
    /// `NotificationService` already declines to post for a visible conversation or
    /// an active app, so this only covers the race where the user activates the app
    /// between posting and delivery. Without it the system's default — drop it — also
    /// loses the message from Notification Center.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Clicking a notification activates the app but does not restore a window that
    /// was closed or minimised, so the conversation would open out of sight.
    private func activateWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows
            .first { $0.canBecomeMain }?
            .makeKeyAndOrderFront(nil)
    }
}
