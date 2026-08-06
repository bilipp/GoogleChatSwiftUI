import AppKit
import Foundation
import Observation
import OSLog
import SwiftData

/// Owns sync state for the signed-in session and drives the sidebar + message pane.
@MainActor
@Observable
final class ChatSessionModel {
    enum SpacesState: Equatable {
        case idle
        case refreshing
        case ready(count: Int)
        case failed(String)
    }

    private(set) var spacesState: SpacesState = .idle

    /// Comparing the enum inline (`state == .refreshing`) inside a view modifier
    /// blows the type checker's budget, so the check lives here.
    var isRefreshingSpaces: Bool {
        if case .refreshing = spacesState { return true }
        return false
    }
    private(set) var loadingSpaceNames: Set<String> = []
    private(set) var messageError: String?

    var scope: SpaceScope = .recent
    var kind: SpaceKind = .all
    /// Muted conversations are hidden by default: the point of muting one is not to
    /// think about it, and Chat itself keeps them out of the way.
    var showsMuted: Bool = false
    /// Filters the sidebar's conversation list.
    var searchText: String = ""

    /// Searches message bodies. Separate from `searchText`, which filters
    /// conversation names — conflating them would make one field mean two things.
    var messageQuery: String = ""
    var messageSearchScope: MessageSearchScope = .allConversations
    /// Message the transcript should jump to, set when a search result is opened.
    var scrollTarget: String?

    var isSearchingMessages: Bool {
        messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }
    var selectedSpaceName: String?
    /// Thread currently open in the inspector, e.g. `spaces/A/threads/B`.
    var selectedThreadName: String?

    private(set) var sendingSpaceNames: Set<String> = []
    private(set) var realtimeStatus: RealtimeCoordinator.Status = .stopped
    private(set) var totalUnread = 0
    /// The user's own reaction history, driving the quick-pick row.
    let recentEmoji = RecentEmojiStore()
    private let notifications = NotificationService()

    private let sync: SyncEngine
    private let realtime: RealtimeCoordinator
    private let profile: GoogleUserProfile?
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "session")

    init(tokenProvider: TokenProvider, container: ModelContainer, profile: GoogleUserProfile?) {
        let client = ChatClient(tokenProvider: tokenProvider)
        let store = ChatStore(modelContainer: container)
        let engine = SyncEngine(client: client, store: store)
        sync = engine
        realtime = RealtimeCoordinator(
            transport: client.transport,
            sync: engine,
            store: store
        )
        self.profile = profile
    }

    // MARK: - Realtime

    func startRealtime() async {
        await realtime.setSelfChatName(profile?.chatUserName)
        await realtime.onStatusChange { [weak self] status in
            Task { @MainActor in self?.realtimeStatus = status }
        }
        await realtime.onIncomingMessage { [weak self] incoming in
            Task { @MainActor in await self?.handleIncoming(incoming) }
        }
        await notifications.requestAuthorization()
        await realtime.start()
        await refreshUnread()
    }

    /// Notifies and re-badges for a message that arrived from the event stream.
    private func handleIncoming(_ incoming: RealtimeCoordinator.IncomingMessage) async {
        // Reading it is what the user is doing right now, so the arrival should not
        // leave a badge behind. Only when the window is actually frontmost: a message
        // in the last-selected space of a backgrounded app is unread like any other.
        let isOnScreen = incoming.spaceName == selectedSpaceName
            && NSApplication.shared.isActive
        if isOnScreen {
            try? await sync.markRead(spaceName: incoming.spaceName)
        }

        await notifications.notify(
            spaceTitle: incoming.spaceTitle,
            senderName: incoming.senderDisplayName,
            body: incoming.body,
            spaceName: incoming.spaceName,
            // Suppressed for the conversation already on screen — an alert for
            // something the user is looking at is pure noise.
            isSpaceVisible: isOnScreen
        )
        await refreshUnread()
    }

    /// Opens a conversation on behalf of something outside the sidebar — a clicked
    /// notification — where the current view may be showing something else entirely.
    func revealSpace(_ spaceName: String) async {
        // A message search replaces the transcript with results, so a click that says
        // "show me this conversation" has to clear it or nothing appears to happen.
        messageQuery = ""
        await openSpace(spaceName)
    }

    /// Recomputes the badge total from the cache.
    func refreshUnread() async {
        do {
            totalUnread = try await sync.totalUnread()
            await notifications.setBadge(totalUnread)
        } catch {
            logger.error("Unread tally failed: \(error.localizedDescription)")
        }
    }

    /// Indexes existing cached messages so search covers them.
    func prepareSearchIndex() async {
        do {
            let indexed = try await sync.backfillSearchIndex()
            if indexed > 0 { logger.info("Indexed \(indexed) message(s) for search") }
        } catch {
            logger.error("Search index backfill failed: \(error.localizedDescription)")
        }
    }

    /// Fetches read state in bounded passes, like title resolution.
    func loadReadStates() async {
        for _ in 0..<40 {
            if Task.isCancelled { return }
            do {
                guard try await sync.pendingReadStateCount() > 0 else { break }
                try await sync.refreshReadStates()
                try? await Task.sleep(for: .milliseconds(250))
            } catch {
                logger.error("Read state pass failed: \(error.localizedDescription)")
                break
            }
        }
        await refreshUnread()
    }

    func stopRealtime() async {
        await realtime.stop()
    }

    /// Closes gaps the event stream may have dropped while the app was asleep or
    /// offline. Events are best-effort, so this is not optional.
    func reconcileSelectedSpace() async {
        guard let spaceName = selectedSpaceName else { return }
        await realtime.reconcile(spaceName: spaceName)
    }

    func refreshSpaces() async {
        spacesState = .refreshing
        do {
            let count = try await sync.refreshSpaces()
            spacesState = .ready(count: count)
        } catch {
            logger.error("Space refresh failed: \(error.localizedDescription)")
            spacesState = .failed(error.localizedDescription)
        }
        // Sections are cheap and shape the whole sidebar, so they refresh with the
        // space list rather than in bounded passes.
        do {
            if let user = profile?.chatUserName {
                try await sync.refreshSections(user: user)
            }
        } catch {
            // Google currently answers users.sections.list with 500 INTERNAL for this
            // account, with either `users/me` or the numeric id, and the scope is
            // granted — so this is server-side, not something the client can fix. The
            // sidebar falls back to one flat group, so it is logged once at info level
            // rather than shouted about as an error on every launch.
            logger.info("Sections unavailable: \(error.localizedDescription)")
        }
        await resolveTitles()
    }

    /// Fetches per-space mute state in bounded passes, like read state.
    func loadNotificationSettings() async {
        for _ in 0..<40 {
            if Task.isCancelled { return }
            do {
                guard try await sync.pendingNotificationSettingCount() > 0 else { break }
                try await sync.refreshNotificationSettings()
                try? await Task.sleep(for: .milliseconds(250))
            } catch {
                logger.error("Notification setting pass failed: \(error.localizedDescription)")
                break
            }
        }
    }

    /// Fills in DM and group-chat names, which Chat does not supply.
    ///
    /// Runs to completion across every space, in bounded concurrent passes, so the
    /// sidebar fills in progressively rather than stalling. Names are cached
    /// permanently, so this is a one-time cost on first launch — but it has to cover
    /// all spaces, not just recent ones, or search would return unnamed rows.
    func resolveTitles() async {
        // Generous ceiling rather than an exact count: a safety net against a bug
        // that never marks spaces resolved, not a real expected bound.
        let maxPasses = 60

        for pass in 0..<maxPasses {
            if Task.isCancelled { return }
            do {
                guard try await sync.pendingTitleCount() > 0 else {
                    if pass > 0 { logger.info("Title resolution complete after \(pass) pass(es)") }
                    return
                }
                try await sync.resolvePendingTitles(excludingUser: profile?.chatUserName)
                // Smooths the request rate: Chat quotas are per-user-per-minute and
                // a few hundred member lookups back-to-back would trip them.
                try? await Task.sleep(for: .milliseconds(250))
            } catch {
                logger.error("Title resolution failed: \(error.localizedDescription)")
                return
            }
        }
        logger.warning("Title resolution hit its pass ceiling with work remaining")
    }

    /// Called when a space is selected. Fetches history only if nothing is cached,
    /// which is what keeps 762 spaces affordable.
    func openSpace(_ spaceName: String) async {
        if selectedSpaceName != spaceName { selectedThreadName = nil }
        selectedSpaceName = spaceName
        messageError = nil
        guard !loadingSpaceNames.contains(spaceName) else { return }

        loadingSpaceNames.insert(spaceName)
        defer { loadingSpaceNames.remove(spaceName) }

        do {
            try await sync.prepareHistory(for: spaceName)
            // Opening a conversation is reading it. Best-effort: failing to clear the
            // badge is not worth an error banner over the messages themselves.
            try? await sync.markRead(spaceName: spaceName)
            await refreshUnread()
        } catch {
            logger.error("History load failed for \(spaceName): \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    /// Marks every space with unread messages as read.
    func markAllRead() async {
        do {
            let names = try await sync.unreadSpaceNames()
            for name in names {
                try? await sync.markRead(spaceName: name)
            }
            await refreshUnread()
        } catch {
            logger.error("Mark all read failed: \(error.localizedDescription)")
        }
    }

    func loadOlderMessages(in spaceName: String) async {
        guard !loadingSpaceNames.contains(spaceName) else { return }
        loadingSpaceNames.insert(spaceName)
        defer { loadingSpaceNames.remove(spaceName) }

        do {
            try await sync.loadMoreHistory(for: spaceName)
        } catch {
            logger.error("Paging failed for \(spaceName): \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    func isLoading(_ spaceName: String) -> Bool {
        loadingSpaceNames.contains(spaceName)
    }

    func isSending(_ spaceName: String) -> Bool {
        sendingSpaceNames.contains(spaceName)
    }

    // MARK: - Writes

    /// Opens a thread in the inspector. Selecting a different space closes it, since
    /// a thread from another conversation would be stale context.
    func openThread(_ threadName: String?) {
        selectedThreadName = threadName
    }

    func send(
        _ text: String,
        to spaceName: String,
        threadName: String? = nil,
        attachments: [PendingAttachment] = []
    ) async {
        messageError = nil
        sendingSpaceNames.insert(spaceName)
        defer { sendingSpaceNames.remove(spaceName) }

        do {
            try await sync.send(
                text: text,
                to: spaceName,
                threadName: threadName,
                attachments: attachments,
                senderName: profile?.chatUserName,
                senderDisplayName: profile?.displayName
            )
            // Sending implies reading. Best-effort: a failure here is not worth
            // surfacing over a successful send.
            try? await sync.markRead(spaceName: spaceName)
        } catch {
            messageError = error.localizedDescription
        }
    }

    func retrySend(messageName: String, text: String, in spaceName: String) async {
        messageError = nil
        sendingSpaceNames.insert(spaceName)
        defer { sendingSpaceNames.remove(spaceName) }

        do {
            try await sync.retrySend(
                messageName: messageName,
                text: text,
                in: spaceName,
                senderName: profile?.chatUserName,
                senderDisplayName: profile?.displayName
            )
        } catch {
            messageError = error.localizedDescription
        }
    }

    func edit(messageName: String, newText: String) async {
        messageError = nil
        do {
            try await sync.edit(messageName: messageName, newText: newText)
        } catch {
            logger.error("Edit failed: \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    func delete(messageName: String) async {
        messageError = nil
        do {
            try await sync.delete(messageName: messageName)
        } catch {
            logger.error("Delete failed: \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    func discardFailedMessage(named name: String) async {
        try? await sync.discard(messageName: name)
    }

    func toggleReaction(_ emoji: String, on messageName: String) async {
        messageError = nil
        do {
            let didAdd = try await sync.toggleReaction(
                emoji: emoji,
                on: messageName,
                selfChatName: profile?.chatUserName
            )
            // Recorded only on success and only on add: a failed call is not a
            // preference, and removing a reaction is not a signal to suggest it.
            if didAdd { recentEmoji.record(emoji) }
        } catch {
            logger.error("Reaction toggle failed: \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    func downloadAttachment(resourceName: String) async throws -> Data {
        try await sync.downloadAttachment(resourceName: resourceName)
    }

    /// Whether the signed-in user authored this message — the gate for edit/delete,
    /// which Chat only permits on your own messages.
    func isOwnMessage(_ message: CachedMessage) -> Bool {
        guard let mine = profile?.chatUserName, let sender = message.senderName else {
            return false
        }
        return mine == sender
    }
}
