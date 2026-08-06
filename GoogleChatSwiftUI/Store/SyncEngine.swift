import Foundation
import OSLog
import SwiftData

/// Coordinates the Chat API and the local cache.
///
/// The governing constraint is scale: this account has 762 spaces. Eagerly walking
/// history for all of them would burn per-user quota for hours and produce nothing
/// the user asked for. So history is fetched per-space, on first open, only.
nonisolated struct SyncEngine: Sendable {
    private let client: ChatClient
    private let store: ChatStore
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "sync")

    /// One screenful plus margin. Small enough to render fast, large enough that
    /// most conversations need no second call.
    static let historyPageSize = 50

    init(client: ChatClient, store: ChatStore) {
        self.client = client
        self.store = store
    }

    /// Refreshes the space list. Cheap — a handful of paginated calls — so it runs
    /// on launch and on demand.
    func refreshSpaces() async throws -> Int {
        let spaces = try await client.allSpaces()
        try await store.upsertSpaces(spaces)
        return spaces.count
    }

    /// Loads the newest page of history for a space, if it isn't already cached.
    ///
    /// Idempotent and safe to call on every selection: it no-ops when messages are
    /// already present, so re-opening a space costs nothing.
    func loadInitialHistoryIfNeeded(for spaceName: String) async throws {
        let state = try await store.backfillState(for: spaceName)
        guard !state.hasMessages else { return }
        try await loadMoreHistory(for: spaceName)
    }

    /// Fetches the next page of older messages, resuming from the stored cursor.
    /// Returns false when the space's history has been walked to the beginning.
    @discardableResult
    func loadMoreHistory(for spaceName: String) async throws -> Bool {
        let state = try await store.backfillState(for: spaceName)
        if state.complete && state.hasMessages { return false }

        let page = try await client.listMessages(
            in: spaceName,
            pageSize: Self.historyPageSize,
            pageToken: state.token
        )
        let messages = page.messages ?? []
        try await store.appendHistory(messages, to: spaceName, nextPageToken: page.nextPageToken)

        logger.info("Backfilled \(messages.count) messages for \(spaceName)")
        return !(page.nextPageToken ?? "").isEmpty
    }

    /// Re-fetches the newest page and merges it.
    ///
    /// The event stream is best-effort, not a durable log, so it must never be the
    /// only source of truth. This closes gaps after sleep, network loss, or a dropped
    /// Pub/Sub message.
    func reconcileHead(of spaceName: String) async throws {
        let page = try await client.listMessages(in: spaceName, pageSize: Self.historyPageSize)
        try await store.mergeMessages(page.messages ?? [], into: spaceName)
    }
}
