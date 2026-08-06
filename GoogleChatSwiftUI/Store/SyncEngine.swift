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
    private let directoryService: DirectoryService
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "sync")

    /// One screenful plus margin. Small enough to render fast, large enough that
    /// most conversations need no second call.
    static let historyPageSize = 50

    init(client: ChatClient, store: ChatStore) {
        self.client = client
        self.store = store
        directoryService = DirectoryService(transport: client.transport)
    }

    /// Refreshes the space list. Cheap — a handful of paginated calls — so it runs
    /// on launch and on demand.
    func refreshSpaces() async throws -> Int {
        let spaces = try await client.allSpaces()
        try await store.upsertSpaces(spaces)
        return spaces.count
    }

    /// Prepares a space for display: backfills it if empty, refreshes its head if not.
    ///
    /// The refresh matters beyond freshness. Previously an already-cached space was
    /// shown as-is, so any field added to the schema after those rows were written
    /// stayed empty until the cache was destroyed. One call per space open keeps
    /// cached content current instead.
    func prepareHistory(for spaceName: String) async throws {
        let state = try await store.backfillState(for: spaceName)
        if state.hasMessages {
            try await reconcileHead(of: spaceName)
        } else {
            try await loadMoreHistory(for: spaceName)
        }
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
        await resolveSenders(from: messages)

        logger.info("Backfilled \(messages.count) messages for \(spaceName)")
        return !(page.nextPageToken ?? "").isEmpty
    }

    // MARK: - Title resolution

    /// How many DM/group-chat titles to resolve per pass. Each costs one API call,
    /// so this is deliberately bounded rather than resolving all 762 spaces.
    static let titleResolutionBatch = 25

    func pendingTitleCount() async throws -> Int {
        try await store.spacesNeedingTitles(limit: Self.titleResolutionBatch).count
    }

    /// Names DMs and unnamed group chats.
    ///
    /// Two stages, because Chat gives us IDs and the People API gives us names:
    /// fetch memberships for a batch of spaces concurrently, then resolve every
    /// distinct user across the whole batch in one directory call. Resolving
    /// per-space instead would repeat the same colleagues dozens of times.
    func resolvePendingTitles(excludingUser selfChatName: String?) async throws {
        let pending = try await store.spacesNeedingTitles(limit: Self.titleResolutionBatch)
        guard !pending.isEmpty else { return }

        var peersBySpace: [String: [String]] = [:]

        await withTaskGroup(of: (String, [String]).self) { group in
            for spaceName in pending {
                group.addTask {
                    do {
                        let peers = try await self.peerIDs(for: spaceName, excluding: selfChatName)
                        return (spaceName, peers)
                    } catch {
                        self.logger.error(
                            "Member lookup failed for \(spaceName): \(error.localizedDescription)"
                        )
                        return (spaceName, [])
                    }
                }
            }
            for await (spaceName, peers) in group {
                peersBySpace[spaceName] = peers
            }
        }

        let everyone = Array(Set(peersBySpace.values.flatMap { $0 }))
        let directory = (try? await directoryService.people(forChatUserNames: everyone)) ?? [:]

        if !directory.isEmpty {
            try? await store.upsertPeople(Array(directory.values))
        }

        for spaceName in pending {
            let peers = peersBySpace[spaceName] ?? []
            let names = peers.compactMap { directory[$0]?.displayName }
            // Group chats read better as "Ana, Ben, Chen" than as a single name.
            let title = names.isEmpty ? nil : names.joined(separator: ", ")
            try? await store.setResolvedTitle(title, peers: peers, for: spaceName)
        }

        logger.info("Resolved \(pending.count) space(s) via \(directory.count) directory profile(s)")
    }

    /// Caches directory profiles for the senders of a batch of messages.
    ///
    /// `Message.sender` carries an ID and an empty `displayName`, so without this
    /// every bubble reads "Unknown". Names are *not* copied onto the messages: the
    /// transcript looks senders up in `CachedUser` instead, so one profile fetch
    /// fixes every message that person has ever sent, including already-cached ones.
    func resolveSenders(from messages: [ChatMessage]) async {
        let ids = Array(Set(messages.compactMap { $0.sender?.name }))
        guard !ids.isEmpty else { return }

        let unknown = (try? await store.unknownUserIDs(ids)) ?? []
        guard !unknown.isEmpty else { return }

        let directory = (try? await directoryService.people(forChatUserNames: unknown)) ?? [:]
        guard !directory.isEmpty else { return }

        try? await store.upsertPeople(Array(directory.values))
        logger.info("Resolved \(directory.count) sender profile(s)")
    }

    /// The other humans in a space.
    ///
    /// Bots are excluded deliberately: naming a DM after the assistant that happens
    /// to be installed in it tells the user nothing about who they were talking to.
    private func peerIDs(for spaceName: String, excluding selfChatName: String?) async throws -> [String] {
        let response = try await client.listMembers(in: spaceName)
        return (response.memberships ?? [])
            .filter(\.isJoined)
            .compactMap(\.member)
            .filter { $0.type != .bot }
            .compactMap(\.name)
            .filter { $0 != selfChatName }
    }

    // MARK: - Writes

    /// Sends a message, showing it locally before the round-trip completes.
    ///
    /// On failure the placeholder is kept and flagged rather than discarded, so the
    /// user's typed text is never silently lost — they can retry or copy it out.
    func send(
        text: String,
        to spaceName: String,
        threadName: String? = nil,
        senderName: String?,
        senderDisplayName: String?
    ) async throws {
        let clientID = ChatClient.newClientMessageID()

        try await store.insertPendingMessage(
            clientID: clientID,
            text: text,
            spaceName: spaceName,
            senderName: senderName,
            senderDisplayName: senderDisplayName,
            threadName: threadName
        )

        do {
            let created = try await client.createMessage(
                in: spaceName,
                text: text,
                threadName: threadName,
                clientMessageID: clientID
            )
            try await store.confirmPendingMessage(
                clientID: clientID,
                spaceName: spaceName,
                server: created
            )
        } catch {
            logger.error("Send failed in \(spaceName): \(error.localizedDescription)")
            try? await store.markSendFailed(
                clientID: clientID,
                spaceName: spaceName,
                reason: error.localizedDescription
            )
            throw error
        }
    }

    /// Retries a failed send by discarding the flagged placeholder and sending afresh.
    func retrySend(
        messageName: String,
        text: String,
        in spaceName: String,
        senderName: String?,
        senderDisplayName: String?
    ) async throws {
        try await store.discardMessage(named: messageName)
        try await send(
            text: text,
            to: spaceName,
            senderName: senderName,
            senderDisplayName: senderDisplayName
        )
    }

    /// Edits a message. The local cache updates only after the server accepts, so a
    /// rejected edit never leaves the UI showing text that does not exist server-side.
    func edit(messageName: String, newText: String) async throws {
        let updated = try await client.updateMessage(name: messageName, text: newText)
        try await store.applyEdit(to: messageName, text: updated.text ?? newText)
    }

    func delete(messageName: String) async throws {
        try await client.deleteMessage(name: messageName)
        try await store.applyDeletion(to: messageName)
    }

    // MARK: - Reactions

    /// Adds or removes the signed-in user's reaction.
    ///
    /// Chat reports reaction *counts* but never whether you are among the reactors,
    /// and offers no field that would. So a toggle first lists the message's
    /// reactions to find your own — one extra call, paid only on interaction rather
    /// than on every message load.
    /// - Returns: whether the reaction was added (as opposed to removed).
    @discardableResult
    func toggleReaction(
        emoji: String,
        on messageName: String,
        selfChatName: String?
    ) async throws -> Bool {
        let listing = try await client.listReactions(messageName: messageName)
        let reactions = listing.reactions ?? []

        let mine = reactions.first { reaction in
            reaction.emoji?.display == emoji && reaction.user?.name == selfChatName
        }

        let didAdd: Bool
        if let mine, let name = mine.name {
            try await client.deleteReaction(name: name)
            try await store.setMyReaction(nil, emoji: emoji, on: messageName)
            didAdd = false
        } else {
            let created = try await client.createReaction(messageName: messageName, unicode: emoji)
            try await store.setMyReaction(created.name, emoji: emoji, on: messageName)
            didAdd = true
        }

        // Re-read so counts reflect everyone's reactions, not just the local nudge.
        let refreshed = try await client.listReactions(messageName: messageName)
        try await store.applyReactionListing(
            refreshed.reactions ?? [],
            for: messageName,
            selfChatName: selfChatName
        )
        return didAdd
    }

    // MARK: - Attachments

    func downloadAttachment(resourceName: String) async throws -> Data {
        try await client.downloadAttachment(resourceName: resourceName)
    }

    func markRead(spaceName: String) async throws {
        let now = Date()
        try await client.markSpaceRead(spaceName: spaceName, upTo: now)
        try await store.markReadLocally(spaceName: spaceName, at: now)
    }

    // MARK: - Read state

    static let readStateBatch = 25

    /// Read state is only checked for spaces active in the last 90 days.
    ///
    /// A space nobody has posted in for months is not going to be unread, and at 762
    /// spaces the calls to prove that would dwarf everything else the app does.
    static let readStateWindow: TimeInterval = 60 * 60 * 24 * 90

    func pendingReadStateCount() async throws -> Int {
        try await store.spacesNeedingReadState(
            limit: Self.readStateBatch,
            activeSince: Date().addingTimeInterval(-Self.readStateWindow)
        ).count
    }

    /// Fetches read state for a batch of spaces concurrently.
    func refreshReadStates() async throws {
        let pending = try await store.spacesNeedingReadState(
            limit: Self.readStateBatch,
            activeSince: Date().addingTimeInterval(-Self.readStateWindow)
        )
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: (String, Date?, Bool).self) { group in
            for spaceName in pending {
                group.addTask {
                    do {
                        let state = try await self.client.spaceReadState(spaceName: spaceName)
                        return (spaceName, state.lastReadTime, true)
                    } catch {
                        self.logger.error(
                            "Read state failed for \(spaceName): \(error.localizedDescription)"
                        )
                        // Marked fetched anyway: a space whose read state cannot be
                        // read would otherwise be retried on every pass forever.
                        return (spaceName, nil, false)
                    }
                }
            }
            for await (spaceName, lastRead, _) in group {
                try? await store.applyReadState(lastRead, for: spaceName)
            }
        }
        logger.info("Fetched read state for \(pending.count) space(s)")
    }

    func totalUnread() async throws -> Int {
        try await store.totalUnread()
    }

    func unreadSpaceNames() async throws -> [String] {
        try await store.unreadSpaceNames()
    }

    /// Removes a failed placeholder that the user chose not to retry.
    func discard(messageName: String) async throws {
        try await store.discardMessage(named: messageName)
    }

    /// Re-fetches the newest page and merges it.
    ///
    /// The event stream is best-effort, not a durable log, so it must never be the
    /// only source of truth. This closes gaps after sleep, network loss, or a dropped
    /// Pub/Sub message.
    func reconcileHead(of spaceName: String) async throws {
        let page = try await client.listMessages(in: spaceName, pageSize: Self.historyPageSize)
        let messages = page.messages ?? []
        try await store.mergeMessages(messages, into: spaceName)
        await resolveSenders(from: messages)
    }
}
