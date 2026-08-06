import AppKit
import Foundation
import OSLog
import UserNotifications

/// Local notifications for incoming messages.
///
/// Deliberately local rather than APNs: the app already receives every message over
/// its own Pub/Sub pull, so there is nothing a push certificate would add — and it
/// would require a server the rest of this design avoids.
@MainActor
final class NotificationService {
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "notifications")
    private var isAuthorized = false

    /// Asked once at startup. A refusal is remembered by the system, so this does not
    /// nag on subsequent launches.
    func requestAuthorization() async {
        do {
            isAuthorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription)")
            isAuthorized = false
        }
    }

    /// Posts a notification for a message that arrived elsewhere.
    ///
    /// - Parameter isSpaceVisible: suppresses the notification when the user is
    ///   already looking at that conversation, where an alert is pure noise.
    func notify(
        spaceTitle: String,
        senderName: String?,
        body: String,
        spaceName: String,
        isSpaceVisible: Bool
    ) async {
        guard isAuthorized, !isSpaceVisible else { return }
        // A frontmost app does not need banners for what is already on screen.
        guard !NSApplication.shared.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = spaceTitle
        if let senderName { content.subtitle = senderName }
        content.body = body
        content.sound = .default
        // Threaded per space so a chatty room collapses into one stack in
        // Notification Center rather than burying everything else.
        content.threadIdentifier = spaceName
        content.userInfo = ["spaceName": spaceName]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Posting notification failed: \(error.localizedDescription)")
        }
    }

    /// Mirrors total unread onto the Dock icon.
    func setBadge(_ count: Int) async {
        guard isAuthorized else { return }
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
