import Foundation
import OSLog
import SwiftData

/// One person behind one emoji on one message.
///
/// `displayName` is nil for anyone the directory could not name — a former colleague,
/// an account outside the workspace — which the UI shows as an unknown reactor rather
/// than dropping. See ``SyncEngine/reactors(on:emoji:selfChatName:)``.
nonisolated struct Reactor: Sendable, Hashable, Identifiable {
    let userID: String
    let displayName: String?
    let photoURL: String?
    let isApp: Bool
    /// The signed-in user, listed first and labelled "You".
    let isSelf: Bool

    var id: String { userID }

    var label: String {
        if isSelf { return "You" }
        return displayName ?? "Unknown user"
    }

    /// Unnamed people sort last: their placeholder is not a name, and letting "Unknown"
    /// land under U would interleave them with real ones.
    var sortKey: String { displayName ?? "\u{10FFFF}" }

    /// The signed-in user first, then everyone else by name.
    ///
    /// A stable order matters more here than it looks: the listing comes back in
    /// whatever order Chat stored the reactions, so without this the same chip shows
    /// the same people in a different sequence every time it is opened.
    static func ordered(_ reactors: [Reactor]) -> [Reactor] {
        reactors.sorted { lhs, rhs in
            if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
            let comparison = lhs.sortKey.localizedCaseInsensitiveCompare(rhs.sortKey)
            // Falling back to the ID keeps two same-named people in a fixed order.
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.userID < rhs.userID
        }
    }
}

/// Coordinates the Chat API and the local cache.
///
/// The governing constraint is scale: this account has 762 spaces. Eagerly walking
/// history for all of them would burn per-user quota for hours and produce nothing
/// the user asked for. So history is fetched per-space, on first open, only.
nonisolated struct SyncEngine: Sendable {
    private let client: ChatClient
    private let store: ChatStore
    private let directoryService: DirectoryService
    /// Shared per engine rather than per chip, because its cache is the whole point.
    private let driveMetadataService: DriveMetadataService
    private let meetSpaceService: MeetSpaceService
    private let logger = AppLog.logger("sync")

    /// One screenful plus margin. Small enough to render fast, large enough that
    /// most conversations need no second call.
    static let historyPageSize = 50

    init(client: ChatClient, store: ChatStore) {
        self.client = client
        self.store = store
        directoryService = DirectoryService(transport: client.transport)
        driveMetadataService = DriveMetadataService(transport: client.transport)
        meetSpaceService = MeetSpaceService(transport: client.transport)
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

    /// Mutes or unmutes a space in Chat itself, so the web client and the phone app
    /// follow.
    ///
    /// Local first, so the sidebar moves at once; put back if Chat refuses, so the
    /// sidebar never claims a mute the other clients do not have.
    func setMuted(_ muted: Bool, for spaceName: String) async throws {
        let previous = try await store.isMuted(spaceName: spaceName)
        try await store.setMuted(muted, for: spaceName)
        do {
            try await client.setMuteSetting(spaceName: spaceName, muted: muted)
        } catch {
            try? await store.setMuted(previous, for: spaceName)
            throw error
        }
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
        var members: [ChatUser] = []

        await withTaskGroup(of: (String, [ChatUser]).self) { group in
            for spaceName in pending {
                group.addTask {
                    do {
                        let peers = try await self.peers(for: spaceName, excluding: selfChatName)
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
                peersBySpace[spaceName] = peers.compactMap(\.name)
                members.append(contentsOf: peers)
            }
        }

        let everyone = Array(Set(peersBySpace.values.flatMap { $0 }))
        let directory = await profiles(for: everyone, from: members)

        if !directory.isEmpty {
            try? await store.upsertPeople(Array(directory.values))
        }

        // Assembled first and written once. A write per space here meant 25 store
        // saves per pass, and every save makes each `@Query` on the main context
        // refetch — see ``ChatStore/setResolvedTitles(_:)``.
        let resolved = pending.map { spaceName in
            let peers = peersBySpace[spaceName] ?? []
            let names = peers.compactMap { directory[$0]?.displayName }
            // Group chats read better as "Ana, Ben, Chen" than as a single name.
            return ResolvedSpaceTitle(
                spaceName: spaceName,
                title: names.isEmpty ? nil : names.joined(separator: ", "),
                peers: peers
            )
        }
        try? await store.setResolvedTitles(resolved)

        logger.info("Resolved \(pending.count) space(s) via \(directory.count) directory profile(s)")
    }

    /// Caches directory profiles for the senders of a batch of messages.
    ///
    /// Chat names senders from the caller's own organisation itself; everyone else
    /// arrives as an ID with an empty `displayName`, and without this would read
    /// "Unknown". Names are *not* copied onto the messages: the
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
        var senders: [ChatUser] = []
        for message in messages {
            guard let sender = message.sender, let id = sender.name else { continue }
            if sender.type == .bot {
                apps.insert(id)
            } else {
                people.insert(id)
                senders.append(sender)
            }
        }

        if !apps.isEmpty {
            try? await store.markAppUsers(Array(apps))
        }

        guard !people.isEmpty else { return }
        let unknown = (try? await store.unknownUserIDs(Array(people))) ?? []
        guard !unknown.isEmpty else { return }

        let resolved = await profiles(for: unknown, from: senders)
        guard !resolved.isEmpty else { return }

        try? await store.upsertPeople(Array(resolved.values))
        logger.info("Resolved \(resolved.count) sender profile(s)")
    }

    /// Re-resolves every cached person against the directory.
    ///
    /// Everything else here resolves a person once and never again — ``resolveSenders``,
    /// the mention pass and the reactor listing all ask ``ChatStore/unknownUserIDs(_:)``
    /// first, which reports anyone already named as known. That is right for what those
    /// passes are doing and it leaves nothing that can correct a row already written: a
    /// colleague who changes their photo keeps the old one until the cache is destroyed,
    /// and a row written from a bad answer stays bad forever. This is that correction.
    ///
    /// Affordable to run on launch because it costs one `batchGet` per 100 cached people
    /// — a handful of requests for a workspace, against the hundreds of calls a space
    /// list already makes. It writes through ``ChatStore/upsertPeople(_:)`` like every
    /// other directory pass, so a hand-typed name still survives it.
    func refreshDirectory() async {
        let ids = (try? await store.personIDs()) ?? []
        guard !ids.isEmpty else { return }

        let directory = (try? await directoryService.people(forChatUserNames: ids)) ?? [:]
        guard !directory.isEmpty else { return }

        try? await store.upsertPeople(Array(directory.values))
        logger.info("Refreshed \(directory.count) directory profile(s)")
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
    private func peers(for spaceName: String, excluding selfChatName: String?) async throws -> [ChatUser] {
        let response = try await client.listMembers(in: spaceName)
        return (response.memberships ?? [])
            .filter(\.isJoined)
            .compactMap(\.member)
            .filter { $0.type != .bot && $0.name != nil && $0.name != selfChatName }
    }

    /// Profiles for these people, keyed by user resource name.
    ///
    /// Chat now sends a name and photo with each user for people in the caller's own
    /// organisation, so those are used as they are. The directory is only asked about
    /// whoever Chat left unnamed, such as people from outside the organisation.
    private func profiles(for ids: [String], from users: [ChatUser]) async -> [String: DirectoryPerson] {
        let wanted = Set(ids)
        var found: [String: DirectoryPerson] = [:]
        for user in users {
            guard let person = user.directoryPerson, wanted.contains(person.chatUserName) else { continue }
            found[person.chatUserName] = person
        }
        let missing = Array(wanted.subtracting(found.keys))
        if !missing.isEmpty {
            let directory = (try? await directoryService.people(forChatUserNames: missing)) ?? [:]
            found.merge(directory) { fromChat, _ in fromChat }
        }
        return found
    }

    /// Names the people not yet in the cache, from Chat's own profiles first.
    private func cacheUnknownPeople(_ ids: [String], from users: [ChatUser]) async {
        let unknown = (try? await store.unknownUserIDs(ids)) ?? []
        guard !unknown.isEmpty else { return }
        let people = await profiles(for: unknown, from: users)
        if !people.isEmpty { try? await store.upsertPeople(Array(people.values)) }
    }

    // MARK: - Direct messages

    /// The conversation with one person, ready to be opened.
    ///
    /// Three steps, cheapest first. The cache answers for every one-to-one conversation
    /// whose members have been resolved, which after the first launch is nearly all of
    /// them. `findDirectMessage` covers the rest — a DM this account has but has not
    /// named yet, and it is authoritative where the cache can only be suggestive. And
    /// `spaces.setup` covers two people who have never spoken, where there is no
    /// conversation to open until one is made.
    ///
    /// Creating one is not as consequential as it sounds: an empty DM is invisible to
    /// the other person until something is sent, so this is the same gesture as typing
    /// someone's name into the web client's search box.
    ///
    /// - Parameter userID: Chat user resource name, e.g. `users/1234567890`.
    /// - Returns: the space resource name.
    func directMessage(with userID: String) async throws -> String {
        if let cached = try await store.directMessageSpaceName(with: userID) { return cached }

        let space: ChatSpace
        do {
            space = try await client.findDirectMessage(with: userID)
        } catch let error as ChatAPIError where error.status == 404 {
            space = try await client.setUpDirectMessage(with: userID)
        }

        try await store.upsertSpaces([space])
        await nameDirectMessage(space.name, peer: userID)
        logger.info("Resolved DM with \(userID) to \(space.name)")
        return space.name
    }

    /// Starts a conversation with several people: a named space when given a name,
    /// otherwise a group chat.
    ///
    /// A group chat with exactly these people is reopened rather than duplicated, the
    /// way the web client does it. A named space is always new; Chat refuses a name
    /// already in use.
    ///
    /// - Parameter members: Chat user resource names, the caller not included.
    /// - Returns: the conversation to open.
    func startConversation(named displayName: String?, description: String?, members: [String]) async throws -> String {
        let space: ChatSpace
        if let displayName {
            space = try await client.setUpSpace(
                displayName: displayName,
                description: description,
                members: members
            )
        } else if let existing = try? await client.findGroupChats(with: members).first {
            space = existing
        } else {
            space = try await client.setUpGroupChat(members: members)
        }

        try await store.upsertSpaces([space])
        logger.info("Started \(space.name) with \(members.count) member(s)")
        return space.name
    }

    /// Titles a DM that has just entered the cache, so the sidebar row about to be
    /// selected reads as the person's name rather than as the "…" an unresolved space
    /// shows.
    ///
    /// It also records the peer, which is what lets the next click resolve from the
    /// cache alone.
    private func nameDirectMessage(_ spaceName: String, peer userID: String) async {
        var name = (try? await store.displayNames(for: [userID]))?[userID]
        if name == nil {
            let directory = (try? await directoryService.people(forChatUserNames: [userID])) ?? [:]
            if !directory.isEmpty { try? await store.upsertPeople(Array(directory.values)) }
            name = directory[userID]?.displayName
        }
        // Left unresolved when the directory has nothing to say: `setResolvedTitle`
        // marks a space resolved whatever it is given, and recording "no name" here
        // would keep the ordinary title pass from ever trying again.
        guard let name else { return }
        try? await store.setResolvedTitle(name, peers: [userID], for: spaceName)
    }

    // MARK: - Mentions

    /// The people the composer's `@` can reach in a space, with their profiles cached.
    ///
    /// The whole room rather than the first page `peers(for:excluding:)` settles for.
    /// A mention is written as a name, so everyone needs one: Chat's own profile where
    /// it sends one, People for the rest. Profiles land in `CachedUser`
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
        var users: [ChatUser] = []
        for membership in members where membership.isJoined {
            guard let member = membership.member, member.type != .bot else { continue }
            guard let name = member.name, name != selfChatName else { continue }
            ids.append(name)
            users.append(member)
        }

        await cacheUnknownPeople(ids, from: users)

        logger.info("Resolved \(ids.count) mentionable member(s) in \(spaceName)")
        return ids
    }

    // MARK: - Meetings

    /// Creates a video meeting and returns the link to it.
    ///
    /// Nothing is stored. A Meet space is not part of the conversation the way a message
    /// is — once its link has been posted, the message *is* the record, and Meet's own
    /// resource name buys nothing this app can use: the API grants an app only the spaces
    /// it created, and none of what it could then read (participants, conference records)
    /// is on screen anywhere here.
    ///
    /// Posting the link is a separate step, deliberately: creating the meeting is the part
    /// that can fail on its own, and the caller has to know it failed *before* clearing
    /// the draft it was going to send with it.
    func createMeetSpace() async throws -> MeetSpace {
        try await meetSpaceService.createSpace()
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
        // user typed, never the markup. The formatted copy travels alongside it, since
        // that is what the transcript renders.
        try await store.applyEdit(
            to: messageName,
            text: updated.text ?? newText,
            formattedText: updated.formattedText
        )
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
            let created = try await client.createReaction(messageName: messageName, emoji: emoji)
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

    /// Who reacted to a message, grouped by emoji.
    ///
    /// Chat's per-message summaries carry counts only, so the names come from the
    /// reactions listing — the same call a toggle makes — and the people in it are
    /// resolved through the directory exactly like message senders are. Anyone the
    /// directory cannot name is still returned: a list of reactors that quietly omits
    /// the ones it failed to look up is worse than one that admits to an unknown.
    ///
    /// Every emoji at once rather than the one that was asked about, because the
    /// listing contains them all regardless — so a reader switching between a message's
    /// reactions pays for one call, not one per chip.
    func reactors(
        on messageName: String,
        selfChatName: String?
    ) async throws -> [String: [Reactor]] {
        let reactions = try await client.allReactions(messageName: messageName)

        var idsByEmoji: [String: Set<String>] = [:]
        for reaction in reactions {
            guard let emoji = reaction.emoji?.display, let id = reaction.user?.name else { continue }
            // A set, so a page boundary crossed while someone was reacting cannot list
            // the same person twice.
            idsByEmoji[emoji, default: []].insert(id)
        }
        guard !idsByEmoji.isEmpty else { return [:] }

        let everyone = Array(Set(idsByEmoji.values.flatMap { $0 }))
        await cacheUnknownPeople(everyone, from: reactions.compactMap(\.user))

        let profiles = (try? await store.profiles(for: everyone)) ?? [:]
        return idsByEmoji.mapValues { ids in
            Reactor.ordered(
                ids.map { id in
                    let profile = profiles[id]
                    return Reactor(
                        userID: id,
                        displayName: profile?.displayName,
                        photoURL: profile?.photoURL,
                        isApp: profile?.isApp ?? false,
                        isSelf: id == selfChatName
                    )
                }
            )
        }
    }

    // MARK: - Attachments

    func downloadAttachment(resourceName: String) async throws -> Data {
        try await client.downloadAttachment(resourceName: resourceName)
    }

    // MARK: - Drive

    /// Title and file kind for a linked Drive file, or nil where it cannot be read.
    /// Cached inside the service, so repeated chips for one file cost one request.
    func driveFile(id: String) async -> DriveFileMetadata? {
        await driveMetadataService.metadata(for: id)
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

        let fetched = await withTaskGroup(of: SpaceReadState.self) { group in
            for spaceName in pending {
                group.addTask {
                    do {
                        let state = try await self.client.spaceReadState(spaceName: spaceName)
                        return SpaceReadState(
                            spaceName: spaceName, lastReadTime: state.lastReadTime
                        )
                    } catch {
                        self.logger.error(
                            "Read state failed for \(spaceName): \(error.localizedDescription)"
                        )
                        // Marked fetched anyway: a space whose read state cannot be
                        // read would otherwise be retried on every pass forever.
                        return SpaceReadState(spaceName: spaceName, lastReadTime: nil)
                    }
                }
            }
            var collected: [SpaceReadState] = []
            for await state in group { collected.append(state) }
            return collected
        }

        // One save for the pass. A write per space made every `@Query` on the main
        // context refetch 25 times over — see ``ChatStore/applyReadStates(_:)``.
        try? await store.applyReadStates(fetched)
        logger.info("Fetched read state for \(pending.count) space(s)")
    }

    // MARK: - Mute

    static let muteSettingBatch = 25

    /// How long a space's mute state is trusted before it is read again. Mute changed
    /// on another device reaches this app no faster than this, or when the space is
    /// opened — Chat sends no event for it.
    static let muteSettingMaxAge: TimeInterval = 60 * 60 * 12

    private func spacesNeedingMuteSetting() async throws -> [String] {
        try await store.spacesNeedingMuteSetting(
            limit: Self.muteSettingBatch,
            activeSince: Date().addingTimeInterval(-Self.readStateWindow),
            staleBefore: Date().addingTimeInterval(-Self.muteSettingMaxAge)
        )
    }

    func pendingMuteSettingCount() async throws -> Int {
        try await spacesNeedingMuteSetting().count
    }

    /// Reads mute state for a batch of spaces concurrently.
    ///
    /// - Returns: how many were read. A space whose read fails is left unfetched, so a
    ///   pass that reads nothing — the scope not yet granted, say — tells the caller to
    ///   stop rather than to keep asking for the same spaces.
    @discardableResult
    func refreshMuteSettings() async throws -> Int {
        let pending = try await spacesNeedingMuteSetting()
        guard !pending.isEmpty else { return 0 }

        let fetched = await withTaskGroup(of: (String, Bool)?.self) { group in
            for spaceName in pending {
                group.addTask {
                    do {
                        let setting = try await self.client.spaceNotificationSetting(spaceName: spaceName)
                        return (spaceName, setting.isMuted)
                    } catch {
                        self.logger.error(
                            "Mute setting failed for \(spaceName): \(error.localizedDescription)"
                        )
                        return nil
                    }
                }
            }
            var collected: [String: Bool] = [:]
            for await case let (name, muted)? in group { collected[name] = muted }
            return collected
        }

        try await store.applyMuteSettings(fetched)
        logger.info("Fetched mute setting for \(fetched.count) of \(pending.count) space(s)")
        return fetched.count
    }

    /// Re-reads one space's mute state, for a space just opened.
    /// - Returns: whether it changed.
    @discardableResult
    func refreshMuteSetting(for spaceName: String) async throws -> Bool {
        let setting = try await client.spaceNotificationSetting(spaceName: spaceName)
        return try await !store.applyMuteSettings([spaceName: setting.isMuted]).isEmpty
    }

    // MARK: - Thread read state

    /// How many threads to check against the server per pass, for the same reason as
    /// `readStateBatch`: one call each, against a per-user-per-minute quota.
    static let threadReadStateBatch = 25

    /// Marks a thread read, here and on the server.
    ///
    /// Local first, so the pane that asked does not wait on a round trip for its read
    /// line; the server write follows and only logs on failure. A mark that failed to
    /// travel is no worse than the local-only marks every build before this one kept.
    /// - Returns: the read mark it replaced.
    @discardableResult
    func markThreadRead(threadName: String) async throws -> Date? {
        let now = Date()
        let previous = try await store.markThreadRead(threadName: threadName, at: now)
        await pushThreadReadTimes([threadName], to: now)
        return previous
    }

    /// Marks a thread unread from its newest reply on.
    /// - Returns: whether there was anything to mark.
    @discardableResult
    func markThreadUnread(threadName: String) async throws -> Bool {
        guard let mark = try await store.markThreadUnread(threadName: threadName) else {
            return false
        }
        await pushThreadReadTimes([threadName], to: mark)
        return true
    }

    func markAllThreadsRead(spaceName: String) async throws {
        let now = Date()
        // Named before clearing — afterwards nothing here is unread to name.
        let unread = try await store.unreadThreadNames(spaceName: spaceName)
        try await store.markAllThreadsRead(spaceName: spaceName, at: now)
        await pushThreadReadTimes(unread, to: now)
    }

    /// How many thread read marks to send at once. Each is its own request against the
    /// same per-user quota as everything else, and "mark all read" in a busy room can
    /// name a few hundred.
    static let threadReadPushConcurrency = 6

    private func pushThreadReadTimes(_ threadNames: [String], to time: Date) async {
        guard !threadNames.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var pending = threadNames.makeIterator()
            for _ in 0..<Self.threadReadPushConcurrency {
                guard let name = pending.next() else { break }
                group.addTask { await self.pushThreadReadTime(name, to: time) }
            }
            while await group.next() != nil {
                if let name = pending.next() {
                    group.addTask { await self.pushThreadReadTime(name, to: time) }
                }
            }
        }
    }

    private func pushThreadReadTime(_ threadName: String, to time: Date) async {
        do {
            try await client.setThreadReadTime(threadName: threadName, to: time)
        } catch {
            logger.error("Thread read mark failed for \(threadName): \(error.localizedDescription)")
        }
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

        let states = await withTaskGroup(of: ThreadReadState.self) { group in
            for threadName in pending {
                group.addTask {
                    do {
                        let state = try await self.client.threadReadState(threadName: threadName)
                        return ThreadReadState(
                            threadName: threadName,
                            lastReadTime: state.lastReadTime
                        )
                    } catch {
                        self.logger.error(
                            "Thread read state failed for \(threadName): \(error.localizedDescription)"
                        )
                        // Recorded as checked regardless, so a thread the endpoint
                        // will not answer for is not retried on every visit.
                        return ThreadReadState(threadName: threadName, lastReadTime: nil)
                    }
                }
            }
            var collected: [ThreadReadState] = []
            for await state in group { collected.append(state) }
            return collected
        }

        // One write for the batch. Applied one at a time, each would have recomputed
        // every thread tally in the space — the same answer, twenty-five times over.
        try? await store.applyThreadReadStates(states)

        logger.info("Checked read state for \(pending.count) thread(s) in \(spaceName)")
        return pending.count
    }

    func spacesWithUnreadThreads() async throws -> [String] {
        try await store.spacesWithUnreadThreads()
    }

    /// Drops the persistent-history log SwiftData keeps and nothing here reads. Local
    /// only. See ``ChatStore/pruneHistory(now:)``.
    func pruneHistory() async throws {
        try await store.pruneHistory()
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

    // MARK: - Message pins

    /// Message names pinned in a space. Pins are shared by everyone in the space and
    /// change rarely, so they are fetched when a space is opened and kept in memory
    /// rather than in the cache.
    func pinnedMessageNames(in spaceName: String) async throws -> [String] {
        try await client.pinnedMessageNames(in: spaceName)
    }

    func setMessagePinned(_ pinned: Bool, messageName: String) async throws {
        if pinned {
            try await client.pinMessage(name: messageName)
        } else {
            try await client.unpinMessage(name: messageName)
        }
    }

    // MARK: - Custom emoji

    /// The workspace's custom emoji, for the reaction picker and for drawing custom
    /// reactions. Image URLs in it expire after minutes, so this is fetched per session
    /// and never cached.
    func customEmojis() async throws -> [ChatEmoji.CustomEmoji] {
        try await client.customEmojis()
    }

    // MARK: - Own availability

    /// The signed-in user's presence and custom status. Never cached: it changes from
    /// other clients and from Chat's own idle detection.
    func availability() async throws -> ChatAvailability {
        try await client.availability()
    }

    func setAvailability(_ change: AvailabilityChange) async throws -> ChatAvailability {
        switch change {
        case .active: try await client.markAsActive()
        case .away: try await client.markAsAway()
        case .doNotDisturb(let end): try await client.markAsDoNotDisturb(until: end)
        case .customStatus(let text, let emoji, let end):
            try await client.setCustomStatus(text: text, emoji: emoji, until: end)
        }
    }

    /// The pinned messages themselves, for the pinned list.
    ///
    /// Read from Chat rather than the cache, because a pin is often on a message old
    /// enough that its history was never downloaded. A space has a handful of pins at
    /// most, so this is a handful of requests. One that fails is left out of the list.
    func pinnedMessages(_ names: [String]) async -> [ChatMessage] {
        let fetched = await withTaskGroup(of: (Int, ChatMessage?).self) { group in
            for (index, name) in names.enumerated() {
                group.addTask { (index, try? await self.client.getMessage(name: name)) }
            }
            var byIndex: [Int: ChatMessage] = [:]
            for await (index, message) in group {
                if let message { byIndex[index] = message }
            }
            return byIndex
        }
        let messages = names.indices.compactMap { fetched[$0] }
        await resolveSenders(from: messages)
        return messages
    }

    /// Asks Chat itself, so a search also finds history the cache has never downloaded.
    ///
    /// The hits are returned to the caller and not written to the cache. A single old
    /// message stored on its own would sit in the transcript above history that was
    /// never fetched, which looks like the messages in between don't exist. Opening a
    /// hit goes through the deep-link path, which pages history until it reaches the
    /// message.
    ///
    /// Senders are looked up as the hits come in, so the rows show names rather than
    /// "Unknown".
    func searchMessages(query: String, inSpace spaceName: String?) async throws -> [ChatMessage] {
        guard let filter = ChatClient.messageSearchFilter(query: query, spaceName: spaceName) else {
            return []
        }
        let page = try await client.searchMessages(filter: filter)
        let messages = (page.results ?? []).map(\.message)
        await resolveSenders(from: messages)
        return messages
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
