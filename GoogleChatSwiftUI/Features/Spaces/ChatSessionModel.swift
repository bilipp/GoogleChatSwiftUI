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

    private let sync: SyncEngine
    private let profile: GoogleUserProfile?
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "session")

    init(tokenProvider: TokenProvider, container: ModelContainer, profile: GoogleUserProfile?) {
        let client = ChatClient(tokenProvider: tokenProvider)
        let store = ChatStore(modelContainer: container)
        sync = SyncEngine(client: client, store: store)
        self.profile = profile
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

    /// Whether the signed-in user authored this message — the gate for edit/delete,
    /// which Chat only permits on your own messages.
    func isOwnMessage(_ message: CachedMessage) -> Bool {
        guard let mine = profile?.chatUserName, let sender = message.senderName else {
            return false
        }
        return mine == sender
    }
}
