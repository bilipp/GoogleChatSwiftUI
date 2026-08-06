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

    private let sync: SyncEngine
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "session")

    init(tokenProvider: TokenProvider, container: ModelContainer) {
        let client = ChatClient(tokenProvider: tokenProvider)
        let store = ChatStore(modelContainer: container)
        sync = SyncEngine(client: client, store: store)
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
}
