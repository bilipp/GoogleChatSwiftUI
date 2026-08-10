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
    private let logger = AppLog.logger("sync")

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

    // MARK: - Sections and mute state

    /// Mirrors the Chat web client's sidebar grouping.
    ///
    /// Cheap: one paginated call for the sections plus one for every space's assignment,
    /// so this runs on launch alongside the space list rather than in bounded passes.
    @discardableResult
    /// - Parameter user: the caller's own resource name. `users/me` is rejected by
    ///   this endpoint with a 500, unlike most of the Chat API.
    func refreshSections(user: String) async throws -> Int {
        let sections = try await client.listSections(user: user)
        guard !sections.isEmpty else {
            logger.info("No sections configured for this account")
            return 0
        }
        let items = try await client.listAllSectionItems(user: user)
        let assigned = try await store.applySections(sections, items: items)
        logger.info("Mapped \(assigned) space(s) into \(sections.count) section(s)")
        return assigned
    }

    /// Pin and mute are local preferences, so these are straight writes to the store
    /// with no request behind them.
    func setPinned(_ pinned: Bool, for spaceName: String) async throws {
        try await store.setPinned(pinned, for: spaceName)
    }

    func reorderPinned(_ spaceNames: [String]) async throws {
        try await store.reorderPinned(spaceNames)
    }

    func setMuted(_ muted: Bool, for spaceName: String) async throws {
        try await store.setMuted(muted, for: spaceName)
    }

    func isMuted(spaceName: String) async throws -> Bool {
        try await store.isMuted(spaceName: spaceName)
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
    ///
    /// App senders — Chat apps and incoming webhooks — take the other branch. People has
    /// no entry for an app, so they are recorded as apps rather than looked up: the call
    /// could only 404, and it would do so on every pass for as long as the space has
    /// webhook messages in it. What the recording buys is the transcript being able to
    /// say "an app posted this" instead of "Unknown".
    func resolveSenders(from messages: [ChatMessage]) async {
        var people: Set<String> = []
        var apps: Set<String> = []
        for message in messages {
            guard let sender = message.sender, let id = sender.name else { continue }
            if sender.type == .bot {
                apps.insert(id)
            } else {
                people.insert(id)
            }
        }

        if !apps.isEmpty {
            try? await store.markAppUsers(Array(apps))
        }

        guard !people.isEmpty else { return }
        let unknown = (try? await store.unknownUserIDs(Array(people))) ?? []
        guard !unknown.isEmpty else { return }

        let directory = (try? await directoryService.people(forChatUserNames: unknown)) ?? [:]
        guard !directory.isEmpty else { return }

        try? await store.upsertPeople(Array(directory.values))
        logger.info("Resolved \(directory.count) sender profile(s)")
    }

    /// Names an app sender by hand.
    ///
    /// The counterpart to ``resolveSenders(from:)`` for the case it cannot serve: Chat
    /// tells this app what an app's *type* is but never what it is called, and the
    /// People API has nothing to say about one either. So the name comes from the person
    /// reading the messages, and is stored exactly where a resolved one would be.
    func setLocalName(_ displayName: String?, for userID: String) async throws {
        try await store.setLocalName(displayName, for: userID)
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

    // MARK: - Mentions

    /// The people the composer's `@` can reach in a space, with their profiles cached.
    ///
    /// The whole room rather than the first page `peerIDs` settles for, and resolved
    /// through People for the usual reason: Chat hands back memberships with an empty
    /// `displayName`, and a mention is written as a name. Profiles land in `CachedUser`
    /// so the views read them the same way they read message senders — one lookup
    /// names this person everywhere in the app, not just in the completion list.
    ///
    /// Bots are left out. The People API cannot name them, so they would arrive as
    /// unnameable rows the composer has nothing to write into the text.
    ///
    /// - Returns: member resource names, the caller's own excluded.
    func mentionableMembers(in spaceName: String, excluding selfChatName: String?) async throws -> [String] {
        let members = try await client.allMembers(in: spaceName)
        // Written as a loop for the same reason as `CachedMessage.apply`: the
        // equivalent filter/compactMap chain over these nested optionals exceeds the
        // type checker's budget.
        var ids: [String] = []
        for membership in members where membership.isJoined {
            guard let member = membership.member, member.type != .bot else { continue }
            guard let name = member.name, name != selfChatName else { continue }
            ids.append(name)
        }

        let unknown = (try? await store.unknownUserIDs(ids)) ?? []
        if !unknown.isEmpty {
            let directory = (try? await directoryService.people(forChatUserNames: unknown)) ?? [:]
            if !directory.isEmpty { try? await store.upsertPeople(Array(directory.values)) }
        }

        logger.info("Resolved \(ids.count) mentionable member(s) in \(spaceName)")
        return ids
    }

    // MARK: - Writes

    /// Sends a message, showing it locally before the round-trip completes.
    ///
    /// On failure the placeholder is kept and flagged rather than discarded, so the
    /// user's typed text is never silently lost — they can retry or copy it out.
    /// - Parameter quotedMessageName: the message this one is an inline reply to. Chat
    ///   will not let a quote cross threads, so `threadName` has to be the quoted
    ///   message's own thread — see `ReplyTarget`.
    /// - Parameter mentions: the people `text` names. Chat carries mentions as markup
    ///   inside the message body rather than in a field of their own, so this is where
    ///   the readable draft becomes the wire form.
    func send(
        text: String,
        to spaceName: String,
        threadName: String? = nil,
        quotedMessageName: String? = nil,
        attachments: [PendingAttachment] = [],
        mentions: [MentionCandidate] = [],
        senderName: String?,
        senderDisplayName: String?
    ) async throws {
        // The echo shows what was typed — `@Ada Lovelace` — while the request carries
        // `<users/123>`. The two only differ for as long as the send is in flight: the
        // server's own copy replaces the placeholder on confirm, and it renders the
        // annotation back as the name anyway.
        try await send(
            text: text,
            wireText: MentionEncoder.encode(text, mentions: mentions),
            to: spaceName,
            threadName: threadName,
            quotedMessageName: quotedMessageName,
            attachments: attachments,
            senderName: senderName,
            senderDisplayName: senderDisplayName
        )
    }

    /// - Parameter wireText: `text` with its mentions already in Chat's markup. Split
    ///   out so a retry can re-post the encoding the first attempt made, rather than
    ///   re-deriving it from a candidate list that no longer exists by then.
    private func send(
        text: String,
        wireText: String,
        to spaceName: String,
        threadName: String?,
        quotedMessageName: String?,
        attachments: [PendingAttachment] = [],
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
            threadName: threadName,
            quotedMessageName: quotedMessageName,
            // Kept on the placeholder so a retry posts the mentions rather than the
            // names as prose — by then the candidate list that produced them is gone.
            wireText: wireText == text ? nil : wireText
        )

        do {
            // Uploaded before the message is created, because a create request can
            // only reference files that already exist server-side.
            var refs: [ChatAttachment.DataRef] = []
            for attachment in attachments {
                refs.append(
                    try await client.uploadAttachment(
                        to: spaceName,
                        filename: attachment.filename,
                        mimeType: attachment.mimeType,
                        data: attachment.data
                    )
                )
            }

            // Read back rather than taken from the cache: a quote carries the quoted
            // message's `lastUpdateTime` as a version check, and the copy on hand may
            // predate an edit made since.
            var quoted: QuotedMessageRef?
            if let quotedMessageName {
                quoted = try await client.quotedMessageRef(for: quotedMessageName)
            }

            let created = try await client.createMessage(
                in: spaceName,
                text: wireText,
                threadName: threadName,
                quoting: quoted,
                attachments: refs,
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
    ///
    /// The placeholder is the only record of where the message was headed, so its
    /// thread, its quote, and the mention markup it was encoded with are read off
    /// before it goes: a retry that dropped any of them would post the text somewhere
    /// — or to someone — the user never chose.
    func retrySend(
        messageName: String,
        text: String,
        in spaceName: String,
        senderName: String?,
        senderDisplayName: String?
    ) async throws {
        let context = try await store.sendContext(for: messageName)
        try await store.discardMessage(named: messageName)
        try await send(
            text: text,
            // Absent for a message that mentioned nobody, where the two are the same.
            wireText: context?.wireText ?? text,
            to: spaceName,
            threadName: context?.threadName,
            quotedMessageName: context?.quotedMessageName,
            senderName: senderName,
            senderDisplayName: senderDisplayName
        )
    }

    /// Edits a message. The local cache updates only after the server accepts, so a
    /// rejected edit never leaves the UI showing text that does not exist server-side.
    ///
    /// - Parameter mentions: who `newText` may name. An edit is a whole new body as far
    ///   as Chat is concerned, so a mention the message already had has to be encoded
    ///   again or it is dropped — see `MessageBubble.saveEdit`.
    func edit(messageName: String, newText: String, mentions: [MentionCandidate] = []) async throws {
        let updated = try await client.updateMessage(
            name: messageName,
            text: MentionEncoder.encode(newText, mentions: mentions)
        )
        // The server's own copy renders mentions back as names, so the cache stores the
        // readable form. `newText` is the fallback for the same reason: it is what the
        // user typed, never the markup.
        try await store.applyEdit(to: messageName, text: updated.text ?? newText)
    }

    /// - Parameter force: also deletes the message's threaded replies, which Chat
    ///   demands of anyone deleting the message a thread starts with. The cache
    ///   tombstones them alongside it, since the server has taken them as well.
    func delete(messageName: String, force: Bool = false) async throws {
        try await client.deleteMessage(name: messageName, force: force)
        try await store.applyDeletion(to: messageName, includingThreadReplies: force)
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

    /// Marks a space unread again — the reverse of `markRead`, and one of the few
    /// gestures in this app that reaches the server.
    ///
    /// Server first, like `markRead`: the mark is Chat's own read state, so the cache
    /// is only updated once Chat has accepted it and the two agree. The mark comes from
    /// the cache because only the cache knows which message to sit behind.
    ///
    /// - Returns: false when the space has nothing that could be unread.
    @discardableResult
    func markUnread(spaceName: String) async throws -> Bool {
        guard let mark = try await store.unreadMark(spaceName: spaceName) else { return false }
        try await client.markSpaceUnread(spaceName: spaceName, before: mark)
        try await store.markUnreadLocally(spaceName: spaceName, at: mark)
        return true
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

    // MARK: - Thread read state

    /// How many threads to check against the server per pass, for the same reason as
    /// `readStateBatch`: one call each, against a per-user-per-minute quota.
    static let threadReadStateBatch = 25

    /// Marks a thread read.
    ///
    /// Local only — deliberately, not for lack of trying. Chat exposes
    /// `getThreadReadState` but no update counterpart, so there is nothing to send.
    /// A thread read here stays unread on chat.google.com.
    /// - Returns: the read mark it replaced.
    @discardableResult
    func markThreadRead(threadName: String) async throws -> Date? {
        try await store.markThreadRead(threadName: threadName)
    }

    func markAllThreadsRead(spaceName: String) async throws {
        try await store.markAllThreadsRead(spaceName: spaceName)
    }

    /// Reconciles unread threads against the server's own read marks.
    ///
    /// Only threads this app currently believes are unread, and only once each: a
    /// thread read on the web client is the one case where the local mark is wrong,
    /// and checking a thread already known to be read could only confirm it.
    /// - Returns: how many threads were checked.
    @discardableResult
    func refreshThreadReadStates(in spaceName: String) async throws -> Int {
        let pending = try await store.threadsNeedingServerReadState(
            spaceName: spaceName,
            limit: Self.threadReadStateBatch
        )
        guard !pending.isEmpty else { return 0 }

        await withTaskGroup(of: (String, Date?).self) { group in
            for threadName in pending {
                group.addTask {
                    do {
                        let state = try await self.client.threadReadState(threadName: threadName)
                        return (threadName, state.lastReadTime)
                    } catch {
                        self.logger.error(
                            "Thread read state failed for \(threadName): \(error.localizedDescription)"
                        )
                        // Recorded as checked regardless, so a thread the endpoint
                        // will not answer for is not retried on every visit.
                        return (threadName, nil)
                    }
                }
            }
            for await (threadName, lastRead) in group {
                try? await store.applyThreadReadState(lastRead, for: threadName)
            }
        }

        logger.info("Checked read state for \(pending.count) thread(s) in \(spaceName)")
        return pending.count
    }

    func spacesWithUnreadThreads() async throws -> [String] {
        try await store.spacesWithUnreadThreads()
    }

    /// Indexes cached messages for search. Local only, so it is cheap to run fully.
    @discardableResult
    func backfillSearchIndex() async throws -> Int {
        try await store.backfillSearchIndex()
    }

    /// Builds thread rows over already-cached messages. Local only, like the search
    /// index backfill.
    @discardableResult
    func backfillThreads() async throws -> Int {
        try await store.backfillThreads()
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

    /// Where a `chat.google.com` link points, as far as the cache can say.
    ///
    /// Cache-only, deliberately. `spaces.messages.get` would confirm that a message
    /// exists, but a message the app has no history around cannot be shown in a
    /// transcript anyway — one row floating above a gap is worse than saying plainly
    /// that the history has not been downloaded yet.
    func destination(of link: ChatDeepLink) async throws -> ChatLinkDestination {
        try await store.destination(of: link)
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
