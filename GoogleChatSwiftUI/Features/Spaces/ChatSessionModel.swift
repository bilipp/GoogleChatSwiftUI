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

    var filter: SpaceFilter = .recent
    var searchText: String = ""
    var selectedSpaceName: String?

    private(set) var sendingSpaceNames: Set<String> = []
    private(set) var realtimeStatus: RealtimeCoordinator.Status = .stopped

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
        await realtime.onStatusChange { [weak self] status in
            Task { @MainActor in self?.realtimeStatus = status }
        }
        await realtime.start()
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
        await resolveTitles()
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
        selectedSpaceName = spaceName
        messageError = nil
        guard !loadingSpaceNames.contains(spaceName) else { return }

        loadingSpaceNames.insert(spaceName)
        defer { loadingSpaceNames.remove(spaceName) }

        do {
            try await sync.loadInitialHistoryIfNeeded(for: spaceName)
        } catch {
            logger.error("History load failed for \(spaceName): \(error.localizedDescription)")
            messageError = error.localizedDescription
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

    func send(_ text: String, to spaceName: String) async {
        messageError = nil
        sendingSpaceNames.insert(spaceName)
        defer { sendingSpaceNames.remove(spaceName) }

        do {
            try await sync.send(
                text: text,
                to: spaceName,
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
            try await sync.toggleReaction(
                emoji: emoji,
                on: messageName,
                selfChatName: profile?.chatUserName
            )
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
