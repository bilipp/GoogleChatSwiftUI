import Foundation
import SwiftData

/// Versioned schema, established before the first real data is written.
///
/// Retrofitting `VersionedSchema` onto a shipped store is the classic SwiftData
/// data-loss trap: without it there is no migration stage to hang a plan on, and
/// the only recovery is destroying the store. Starting versioned costs nothing now.
enum ChatSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            CachedSpace.self,
            CachedMessage.self,
            CachedThread.self,
            CachedUser.self,
            CachedReaction.self,
            CachedAttachment.self,
        ]
    }
}

/// No stages yet, and adding an optional attribute does not need one.
///
/// A declared `.lightweight` stage cannot express that change here, and crashes on the
/// attempt: one set of `@Model` classes serves every `VersionedSchema`, so the moment a
/// property is added the *old* version describes the new shape too. The stage becomes a
/// mapping from a schema to itself while the store on disk is still the older one, and
/// CoreData raises rather than returns — past the `try` that would have rebuilt the
/// cache. SwiftData's own inference handles the added optional instead.
///
/// A stage earns its place when a change needs data moved rather than a column added —
/// and that is the change that also needs the two schemas spelled out separately.
enum ChatMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ChatSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

// MARK: - Models

@Model
final class CachedSpace {
    /// Chat resource name, e.g. `spaces/AAAA1111`. Stable across everything.
    @Attribute(.unique) var name: String

    var displayName: String?
    var spaceTypeRaw: String?
    var threadingStateRaw: String?
    var spaceDescription: String?
    var createTime: Date?
    var lastActiveTime: Date?
    var memberCount: Int?

    /// Google's own web URL for this conversation, from `Space.spaceUri`.
    ///
    /// Stored on the chance of getting it rather than in expectation: the field is
    /// documented and declared in the discovery document, and no `spaces.list` response
    /// has ever carried it. `ChatDeepLink` builds message links from `spaceType` and
    /// prefers this whenever it does arrive, so a change of URL scheme at Google's end
    /// would be picked up rather than needing to be noticed.
    var spaceUri: String?

    /// Peer names for DMs and unnamed group chats, resolved from the members API and
    /// cached because Chat never supplies a `displayName` for them.
    var resolvedTitle: String?
    /// Set once membership resolution has been attempted, successfully or not, so a
    /// space with genuinely unnameable members isn't retried on every launch.
    var didResolveTitle: Bool = false
    /// Human members other than the signed-in user, kept so the sidebar can show
    /// their avatars without re-querying memberships.
    var peerUserIDs: [String] = []

    /// Pagination cursor for backfilling this space's history. Nil once exhausted.
    var backfillPageToken: String?
    /// Whether history has been walked to the beginning.
    var backfillComplete: Bool = false
    /// When this space's messages were last reconciled against the server.
    var lastSyncedAt: Date?

    /// Navigation section this space sits in, from the sections API — the same
    /// grouping the Chat web client shows in its sidebar.
    var sectionName: String?
    var sectionTitle: String?
    var sectionSortOrder: Int = 0

    /// Pinned and muted are this app's own, set here and stored here.
    ///
    /// Neither comes from Chat. Pinning has no API representation at all — no field
    /// on `Space`, no section type, no method — and the mute signal the API does
    /// offer did not match what this account sees on chat.google.com, so trusting it
    /// produced a sidebar that disagreed with the web client. Local state is at least
    /// honest about being local: it is exactly what the user set here.
    ///
    /// The consequence is that neither travels. Pinning a space here leaves it
    /// unpinned in the web client, and vice versa.
    var isPinned: Bool = false
    var isMuted: Bool = false
    /// Position within the pinned group, lowest first.
    ///
    /// An explicit index rather than a pin timestamp, because the group is
    /// user-orderable: a timestamp can only express "when", and reordering by
    /// rewriting timestamps would encode the arrangement in a field that claims to
    /// mean something else. Meaningless while `isPinned` is false.
    var pinnedOrder: Int = 0

    /// The signed-in user's read position, from the read-state API.
    var lastReadTime: Date?
    /// Distinguishes "read at the epoch" from "never fetched" — without it an
    /// unfetched space would be indistinguishable from a fully unread one and every
    /// space would light up as unread on first launch.
    var didFetchReadState: Bool = false
    /// Messages newer than `lastReadTime`, counted from cached history. Chat exposes
    /// no unread count of its own, only a read timestamp.
    var unreadCount: Int = 0

    /// Threads in this space holding replies the user has not read.
    ///
    /// Tracked apart from `unreadCount` because a thread reply never appears in the
    /// main transcript of a threaded space, so the space-level read mark cannot
    /// account for it: opening the space marks it read and the reply becomes both
    /// unbadged and invisible. See `CachedThread.lastReadTime`.
    var unreadThreadCount: Int = 0

    /// Unread replies the space-level count cannot see — those at or before
    /// `lastReadTime`, which is every one of them once the space has been opened.
    ///
    /// Kept separate so the Dock badge can add the two without double-counting the
    /// replies that are newer than the read mark and therefore already in
    /// `unreadCount`.
    var unreadThreadReplyCount: Int = 0

    /// Only claimed when read state is actually known.
    var hasUnread: Bool {
        guard didFetchReadState, let lastReadTime, let lastActiveTime else { return false }
        return lastActiveTime > lastReadTime
    }

    /// What this space contributes to the badge: unread messages plus the unread
    /// replies hidden behind the read mark.
    var totalUnread: Int { unreadCount + unreadThreadReplyCount }

    /// Anything left to read here at all — a counted message, a timestamp-only signal
    /// from a space with no history cached, or a reply waiting in a thread.
    ///
    /// The three are separate counters because they are learned in different ways, but
    /// "is this row bold" and "does Mark as Read have anything to do" are the same
    /// question, and it is answered here so they cannot drift apart.
    var isUnread: Bool { unreadCount > 0 || hasUnread || unreadThreadCount > 0 }

    /// Cascade: deleting a cached space should not orphan its messages.
    @Relationship(deleteRule: .cascade, inverse: \CachedMessage.space)
    var messages: [CachedMessage] = []

    /// Likewise for its threads, which are index rows over those messages.
    @Relationship(deleteRule: .cascade, inverse: \CachedThread.space)
    var threads: [CachedThread] = []

    init(name: String) {
        self.name = name
    }

    var spaceType: ChatSpace.SpaceType? {
        spaceTypeRaw.flatMap(ChatSpace.SpaceType.init(rawValue:))
    }

    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let resolvedTitle, !resolvedTitle.isEmpty { return resolvedTitle }
        switch spaceType {
        case .directMessage: return didResolveTitle ? "Direct message" : "…"
        case .groupChat: return didResolveTitle ? "Group chat" : "…"
        default: return name
        }
    }

    /// DMs and unnamed group chats need a members lookup to be nameable at all.
    var needsTitleResolution: Bool {
        guard !didResolveTitle else { return false }
        guard displayName?.isEmpty ?? true else { return false }
        return spaceType == .directMessage || spaceType == .groupChat
    }

    /// Only fully threaded spaces hide replies from the main transcript. Chat itself
    /// renders grouped and unthreaded spaces as one flat conversation, so mirroring
    /// that avoids the app disagreeing with the web client about where a reply lives.
    var isThreaded: Bool { threadingStateRaw == "THREADED_MESSAGES" }

    func apply(_ remote: ChatSpace) {
        displayName = remote.displayName
        spaceTypeRaw = remote.spaceType?.rawValue
        threadingStateRaw = remote.spaceThreadingState
        spaceDescription = remote.spaceDetails?.description
        // Never cleared by a response that omits it: a stored URI stays useful, and a
        // nil would take the exact `room`/`dm` answer away again.
        if let uri = remote.spaceUri, !uri.isEmpty { spaceUri = uri }
        createTime = remote.createTime
        // Never moves backwards. A refresh that races a live message would otherwise
        // undo the bump the event stream just applied, since the server's own space
        // record lags the message that caused it.
        if let remoteActive = remote.lastActiveTime,
           remoteActive > (lastActiveTime ?? .distantPast) {
            lastActiveTime = remoteActive
        }
        memberCount = remote.membershipCount?.joinedDirectHumanUserCount
    }
}

@Model
final class CachedMessage {
    /// Chat resource name, e.g. `spaces/AAAA/messages/BBBB`.
    /// This is the dedupe key that makes pagination and the event stream converge.
    @Attribute(.unique) var name: String

    var text: String?

    /// The same body with its formatting still in it — see ``ChatTextSource``.
    ///
    /// Stored beside `text` rather than instead of it because the two answer different
    /// questions. This one is what the transcript renders, since `text` has had the
    /// markup taken out of it and can no longer say a span was code. `text` is what
    /// search indexes and what a notification banner shows, where markup would be
    /// noise, and it is the fallback whenever this is nil — a locally composed message
    /// still waiting on the server, or a row cached before this column existed.
    var formattedText: String?

    /// Chat's own plain-text stand-in for card messages.
    var fallbackText: String?
    var createTime: Date?
    var lastUpdateTime: Date?
    var deleteTime: Date?
    var senderName: String?
    var senderDisplayName: String?
    /// `HUMAN` or `BOT`, as Chat reported it.
    ///
    /// Worth storing because it is the *only* thing the API says about a sender beyond
    /// the ID: under user authentication `displayName` never arrives, for people or for
    /// apps. So this is what separates an app — a Chat app or an incoming webhook — from
    /// a colleague the People lookup has not answered for yet, and the two need telling
    /// apart because only one of them will ever be named by a request.
    var senderTypeRaw: String?
    var threadName: String?
    var isThreadReply: Bool = false
    var attachmentCount: Int = 0

    /// URLs of the GIFs attached to this message — see ``AttachedGif``.
    ///
    /// Kept apart from `attachments` because Chat keeps them apart, and the difference is
    /// not cosmetic: a GIF from the picker was never uploaded to the space, so it has no
    /// media resource to fetch and no filename to save it under. A public URL is the whole
    /// of what the API says about one, which is why these are stored as strings rather
    /// than as rows of their own.
    var attachedGifURIs: [String] = []

    /// Set while a locally-composed message is in flight. The row is rendered
    /// immediately so sending feels instant, then either confirmed by the server
    /// response or rolled back.
    var isPending: Bool = false
    /// Non-nil when a send failed and the row is offering a retry.
    var sendFailureReason: String?

    /// What was actually posted, when that differs from `text`.
    ///
    /// A message with mentions is two strings: the readable one the user typed and
    /// sees echoed, and the same text with each name rewritten as `<users/123>` — the
    /// only form in which Chat will register a mention. The wire form is kept here
    /// because a retry happens long after the composer that produced it has been
    /// cleared, and re-deriving it is impossible: nothing left in the app knows which
    /// `@Ada Lovelace` was a mention and which was prose.
    ///
    /// Nil for the overwhelming majority of messages, which mention nobody, and
    /// meaningless once the server's own copy replaces the placeholder.
    var wireText: String?

    /// Chat user IDs mentioned in this message, from its annotations.
    var mentionedUserIDs: [String] = []

    /// The message this one is an inline reply to, when it is one.
    ///
    /// A pointer rather than a copy, so a quote shows the current text of what it
    /// quotes — including an edit or a deletion that landed afterwards, which is what
    /// the web client does too.
    var quotedMessageName: String?

    /// The server's snapshot of the quoted message's author and text.
    ///
    /// The fallback for when `quotedMessageName` points at something not in the cache:
    /// a reply can quote a message older than the history backfilled for this space,
    /// and without the snapshot the quote would be an empty box.
    ///
    /// For a forward it is not a fallback but the content itself — see ``isForwarded``.
    var quotedMessageSender: String?
    var quotedMessageText: String?

    /// `REPLY` or `FORWARD`, as Chat reported it. Nil for a plain reply, which Chat
    /// leaves unset, and for rows cached before this column existed.
    var quoteTypeRaw: String?

    /// The conversation a forwarded message was taken out of, and what it was called at
    /// the time — see ``ForwardedMetadata``. Both nil unless this is a forward, and
    /// `forwardedFromSpace` can be a space this account is not a member of.
    var forwardedFromSpace: String?
    var forwardedFromSpaceTitle: String?

    /// The forwarded message's body with its markup still in it, and the mentions and
    /// rich links Chat parsed out of it, kept as raw JSON for the same reason
    /// ``richLinksJSON`` is.
    ///
    /// Populated for forwards only: Chat sends a reply's snapshot as bare text, because a
    /// reply shows one flattened line of it, while a forward *is* the original and is
    /// rendered as fully as the message that carries it.
    var quotedMessageFormattedText: String?
    var quotedAnnotationsJSON: Data?

    /// Copies of the forwarded message's attachment metadata.
    ///
    /// Stored as JSON rather than as ``CachedAttachment`` rows, and that is not a
    /// shortcut: an attachment row is keyed uniquely by its resource name, and these name
    /// attachments belonging to a message in *another* space. Two people forwarding the
    /// same picture, or a forward of something this account already has cached, would
    /// collide on that key and the row would be handed to whichever message was written
    /// last — quietly moving an attachment off the message it belongs to.
    var quotedAttachmentsJSON: Data?

    /// Lowercased message text, kept non-optional purely so it can be queried.
    ///
    /// SwiftData cannot reliably translate a predicate over an optional String —
    /// force-unwrapping inside `#Predicate` throws at runtime, which is how the
    /// display-name backfill silently failed earlier. A plain non-optional column
    /// sidesteps the problem, and lowercasing at write time makes search a simple
    /// `contains` rather than a locale-sensitive comparison the store can't index.
    var searchableText: String = ""

    /// Rich-link annotations kept as raw JSON, for the same reason as cards: a nested
    /// tree that is only ever read and re-rendered, never queried.
    var richLinksJSON: Data?

    /// `cardsV2` kept as raw JSON.
    ///
    /// Cards are a deeply nested, recursive tree of a dozen widget types. Modelling
    /// that as SwiftData entities would be an enormous schema for data that is only
    /// ever read and re-rendered, never queried or mutated — so it is stored as a
    /// blob and decoded on demand.
    var cardsJSON: Data?

    var space: CachedSpace?

    /// Set only in fully threaded spaces, where a thread is a place you can navigate
    /// to. Elsewhere Chat still assigns every message a thread name, but replies are
    /// rendered inline, so an index row over them would describe nothing.
    var thread: CachedThread?

    @Relationship(deleteRule: .cascade, inverse: \CachedReaction.message)
    var reactions: [CachedReaction] = []

    @Relationship(deleteRule: .cascade, inverse: \CachedAttachment.message)
    var attachments: [CachedAttachment] = []

    init(name: String) {
        self.name = name
    }

    var isDeleted: Bool { deleteTime != nil }

    /// Whether an app posted this rather than a person.
    ///
    /// Nil for rows cached before the type was stored, which reads as false — see
    /// ``SenderIdentity``, which also consults the sender's own row so one typed
    /// message identifies that sender's whole back catalogue.
    var isAppSender: Bool { senderTypeRaw == ChatUser.UserType.bot.rawValue }

    /// Decoded on demand, and not cheap — see ``DecodedMessageContent``, which is what
    /// the transcript reads through. Views must not call this per body evaluation.
    var cards: [ChatCard] {
        guard let cardsJSON, !isDeleted else { return [] }
        guard let decoded = try? JSONDecoder().decode([ChatCardWithID].self, from: cardsJSON) else {
            return []
        }
        return decoded.compactMap(\.card)
    }

    var hasCards: Bool { cardsJSON != nil && !isDeleted }

    /// Whether this message carries GIFs from Chat's picker.
    var hasGifs: Bool { !attachedGifURIs.isEmpty && !isDeleted }

    /// Whether this message carries another one forwarded into the conversation, rather
    /// than quoting one that is already in it.
    ///
    /// The distinction decides how the quote is rendered and where its original lives, so
    /// it is asked in one place. Only an explicit `FORWARD` counts: Chat omits the field
    /// for a reply, and rows cached before the column existed have nothing in it.
    var isForwarded: Bool {
        quoteTypeRaw == QuotedMessageMetadata.forwardQuoteType && quotedMessageName != nil
    }

    /// Attachments that came with a forwarded message. Decoded on demand, like cards, and
    /// read through the same memo — see ``DecodedMessageContent``.
    var quotedAttachments: [ChatAttachment] {
        guard let quotedAttachmentsJSON, !isDeleted else { return [] }
        guard let decoded = try? JSONDecoder().decode(
            [ChatAttachment].self,
            from: quotedAttachmentsJSON
        ) else { return [] }
        return decoded
    }

    /// Annotations Chat parsed out of a forwarded message's own body.
    var quotedAnnotations: [ChatAnnotation] {
        guard let quotedAnnotationsJSON, !isDeleted else { return [] }
        guard let decoded = try? JSONDecoder().decode(
            [ChatAnnotation].self,
            from: quotedAnnotationsJSON
        ) else { return [] }
        return decoded
    }

    /// Smart chips Chat recognised in the text — Drive files, Calendar events, Meet
    /// links. Decoded on demand, like cards, and read through the same memo.
    var richLinks: [RichLinkMetadata] {
        guard let richLinksJSON, !isDeleted else { return [] }
        guard let decoded = try? JSONDecoder().decode([ChatAnnotation].self, from: richLinksJSON)
        else { return [] }
        return decoded.compactMap(\.richLinkMetadata)
    }

    /// Text to show in the bubble. Empty when a card carries the whole message, so
    /// the bubble can be omitted entirely rather than showing a stub above the card.
    ///
    /// Empty for a forward with no comment on it too, and for the same reason: the
    /// forwarded message renders as its own block beneath, and a bubble saying
    /// "Attachment" above it would be describing the block rather than the message.
    var displayText: String {
        if isDeleted { return "Message deleted" }
        if let text, !text.isEmpty { return text }
        // GIFs join cards and forwards here rather than falling through to the
        // attachment stub below: all three render as their own block beneath the bubble,
        // and a bubble reading "GIF" above a GIF describes the block, not the message.
        if hasCards || isForwarded || hasGifs { return "" }
        if attachmentCount > 0 { return "Attachment" }
        return ""
    }

    /// Plain-text summary for notifications and the menu bar, where a card cannot
    /// be rendered.
    var summaryText: String {
        if isDeleted { return "Message deleted" }
        if let text, !text.isEmpty { return text }
        if let fallbackText, !fallbackText.isEmpty { return fallbackText }
        if hasCards { return "Card message" }
        // Before the attachment fallback: a forward's own attachment count is zero, and
        // what a banner should say about one is what was forwarded, not that something
        // was. Prefixed because the notification is the only place that says so —
        // there is no forwarded block out here to make it obvious.
        if isForwarded, let quoted = quotedMessageText, !quoted.isEmpty {
            return "Forwarded: \(quoted)"
        }
        if attachmentCount > 0 { return "Attachment" }
        if hasGifs { return "GIF" }
        if isForwarded { return "Forwarded message" }
        return "Message"
    }

    /// Builds the search column from every text-bearing field, so a card message is
    /// findable by its fallback text even though it has no body of its own.
    ///
    /// - Parameter forwarded: the body of a message forwarded into this one, which is
    ///   included for the same reason: it is this message's content, and a forward with no
    ///   comment on it has no other text to be found by. A *reply*'s quoted text is
    ///   deliberately left out — indexing it would make every reply a hit for the message
    ///   it answers.
    static func searchIndex(text: String?, fallback: String?, forwarded: String? = nil) -> String {
        [text, fallback, forwarded]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    func apply(_ remote: ChatMessage) {
        text = remote.text
        formattedText = remote.formattedText
        fallbackText = remote.fallbackText
        let quote = remote.quotedMessageMetadata
        searchableText = Self.searchIndex(
            text: remote.text,
            fallback: remote.fallbackText,
            forwarded: quote?.isForward == true ? quote?.quotedMessageSnapshot?.text : nil
        )
        // Re-encoded rather than carrying the original bytes: the wire payload is not
        // retained after decoding, and round-tripping through our own models keeps the
        // stored shape in step with what the renderer expects.
        cardsJSON = (remote.cardsV2?.isEmpty == false)
            ? try? JSONEncoder().encode(remote.cardsV2)
            : nil

        let richLinks = (remote.annotations ?? []).filter { $0.richLinkMetadata != nil }
        richLinksJSON = richLinks.isEmpty ? nil : try? JSONEncoder().encode(richLinks)
        createTime = remote.createTime
        lastUpdateTime = remote.lastUpdateTime
        deleteTime = remote.deleteTime
        senderName = remote.sender?.name
        senderDisplayName = remote.sender?.displayName
        // Never cleared by a response that omits it, for the same reason as a space's
        // URI: knowing a sender is an app is not something to lose to a payload that
        // happened not to say.
        if let type = remote.sender?.type?.rawValue { senderTypeRaw = type }
        threadName = remote.thread?.name
        isThreadReply = remote.threadReply ?? false
        attachmentCount = remote.attachment?.count ?? 0
        attachedGifURIs = (remote.attachedGifs ?? []).compactMap(\.uri)
        applyQuote(remote.quotedMessageMetadata)
        // Written as a loop: the equivalent filter/compactMap chain over an optional
        // array of nested optionals exceeds the type checker's budget.
        var mentions: [String] = []
        for annotation in remote.annotations ?? [] where annotation.type == "USER_MENTION" {
            if let id = annotation.userMention?.user?.name {
                mentions.append(id)
            }
        }
        mentionedUserIDs = mentions
    }

    /// Stores what this message quotes, whichever of Chat's two kinds of quote it is.
    ///
    /// The forward-only half is written unconditionally rather than only for forwards, so
    /// that a payload arriving without it — an edit of a forward, a message that stopped
    /// being one — clears the columns instead of leaving a stale block behind.
    private func applyQuote(_ remote: QuotedMessageMetadata?) {
        quotedMessageName = remote?.name
        quoteTypeRaw = remote?.quoteType
        let snapshot = remote?.quotedMessageSnapshot
        quotedMessageSender = snapshot?.sender
        quotedMessageText = snapshot?.text
        quotedMessageFormattedText = snapshot?.formattedText
        forwardedFromSpace = remote?.forwardedMetadata?.space
        forwardedFromSpaceTitle = remote?.forwardedMetadata?.spaceDisplayName

        let attachments = snapshot?.attachments ?? []
        quotedAttachmentsJSON = attachments.isEmpty
            ? nil
            : try? JSONEncoder().encode(attachments)

        // Mentions and rich links only. The rest of what Chat annotates — slash commands,
        // the marker on someone being added to a thread — describes an action taken in the
        // original conversation, and there is nothing to do with it here.
        let annotations = (snapshot?.annotations ?? []).filter {
            $0.type == "USER_MENTION" || $0.richLinkMetadata != nil
        }
        quotedAnnotationsJSON = annotations.isEmpty
            ? nil
            : try? JSONEncoder().encode(annotations)
    }
}

/// One thread in a threaded space, with the user's read position in it.
///
/// Exists because a thread reply is invisible from the main transcript and the
/// space-level read mark is the wrong instrument for it: opening the space sets that
/// mark to now, which would silently declare every unread reply read. A thread
/// therefore carries its own mark, advanced only by actually opening the thread.
///
/// Reads do not travel. Chat's thread read state is readable
/// (`users.spaces.threads.getThreadReadState`) but has no update method — unlike
/// space read state, which has both — so the app can learn where the web client
/// thinks you are but never tell it where you got to here.
@Model
final class CachedThread {
    /// Chat resource name, e.g. `spaces/AAAA/threads/BBBB`.
    @Attribute(.unique) var name: String

    var space: CachedSpace?

    /// Newest reply, excluding the thread's root message.
    var lastReplyTime: Date?
    /// Newest message of any kind, for ordering the thread list.
    var lastActivityTime: Date?
    /// Replies, excluding the root and deleted messages.
    var replyCount: Int = 0

    /// The user's read position in this thread.
    var lastReadTime: Date?
    /// Whether `lastReadTime` means anything yet.
    ///
    /// A thread cached before its space's read state arrived has nothing to compare
    /// replies against. Without this flag it would be indistinguishable from a thread
    /// read at the epoch, and every thread in the cache would light up unread on
    /// first launch — the same trap `CachedSpace.didFetchReadState` avoids.
    var didSeedReadState: Bool = false
    /// Whether the server's own thread read state has been consulted, so the check
    /// is paid once per thread rather than on every visit to the list.
    var didCheckServerReadState: Bool = false

    /// Replies newer than `lastReadTime`. Zero until the read mark is seeded.
    var unreadReplyCount: Int = 0

    /// Nullify, not cascade: this is an index over messages the space owns, and
    /// dropping a thread row must never take the conversation with it.
    @Relationship(deleteRule: .nullify, inverse: \CachedMessage.thread)
    var messages: [CachedMessage] = []

    init(name: String) {
        self.name = name
    }

    var hasUnread: Bool { unreadReplyCount > 0 }

    /// The message the thread hangs off — the one shown in the main transcript.
    var root: CachedMessage? {
        messages.first { !$0.isThreadReply }
            ?? messages.min { ($0.createTime ?? .distantPast) < ($1.createTime ?? .distantPast) }
    }
}

@Model
final class CachedReaction {
    /// `<messageName>|<emoji>` — one row per distinct emoji on a message.
    @Attribute(.unique) var key: String
    var emoji: String
    var count: Int
    /// The signed-in user's own reaction resource name, when they have reacted.
    /// Chat never reports this in message summaries, so it is filled in lazily.
    var myReactionName: String?

    var message: CachedMessage?

    init(key: String, emoji: String, count: Int) {
        self.key = key
        self.emoji = emoji
        self.count = count
    }

    var reactedByMe: Bool { myReactionName != nil }
}

@Model
final class CachedAttachment {
    /// Chat resource name of the attachment.
    @Attribute(.unique) var name: String
    var contentName: String?
    var contentType: String?
    var thumbnailURI: String?
    var downloadURI: String?
    /// Pointer for `media.download`, absent for Drive-hosted files.
    var dataResourceName: String?

    var message: CachedMessage?

    init(name: String) {
        self.name = name
    }

    /// What the transcript renders this as. The name, the icon and whether the bytes can
    /// be fetched at all live on ``AttachmentDisplay``, which a forwarded attachment can
    /// reach too — it has no row here to hang them off.
    var display: AttachmentDisplay { AttachmentDisplay(self) }
}

@Model
final class CachedUser {
    /// Chat resource name, e.g. `users/1234567890`.
    @Attribute(.unique) var name: String
    var displayName: String?
    /// From the People API — Chat itself never supplies avatars.
    var photoURL: String?

    /// A Chat app or an incoming webhook rather than a person.
    ///
    /// Recorded from `Message.sender.type` rather than from a lookup, because there is
    /// no lookup: the People API has no entry for an app, so a row for one exists only
    /// because a message named it. Kept here rather than only on the message so that a
    /// single message carrying the type identifies every message that sender has ever
    /// posted, including history cached before the app stored types at all.
    var isApp: Bool = false

    /// Whether ``displayName`` was typed by the user rather than resolved.
    ///
    /// The only way an app gets a name in this app: Chat will not say what an app is
    /// called under user authentication, and People cannot be asked. Flagged so a
    /// directory pass can never quietly overwrite the one name a person went to the
    /// trouble of supplying.
    var isLocallyNamed: Bool = false

    init(name: String) {
        self.name = name
    }
}
