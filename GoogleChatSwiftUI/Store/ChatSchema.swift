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
            CachedUser.self,
            CachedReaction.self,
            CachedAttachment.self,
        ]
    }
}

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

    /// Only claimed when read state is actually known.
    var hasUnread: Bool {
        guard didFetchReadState, let lastReadTime, let lastActiveTime else { return false }
        return lastActiveTime > lastReadTime
    }

    /// Cascade: deleting a cached space should not orphan its messages.
    @Relationship(deleteRule: .cascade, inverse: \CachedMessage.space)
    var messages: [CachedMessage] = []

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
    /// Chat's own plain-text stand-in for card messages.
    var fallbackText: String?
    var createTime: Date?
    var lastUpdateTime: Date?
    var deleteTime: Date?
    var senderName: String?
    var senderDisplayName: String?
    var threadName: String?
    var isThreadReply: Bool = false
    var attachmentCount: Int = 0

    /// Set while a locally-composed message is in flight. The row is rendered
    /// immediately so sending feels instant, then either confirmed by the server
    /// response or rolled back.
    var isPending: Bool = false
    /// Non-nil when a send failed and the row is offering a retry.
    var sendFailureReason: String?

    /// Chat user IDs mentioned in this message, from its annotations.
    var mentionedUserIDs: [String] = []

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

    @Relationship(deleteRule: .cascade, inverse: \CachedReaction.message)
    var reactions: [CachedReaction] = []

    @Relationship(deleteRule: .cascade, inverse: \CachedAttachment.message)
    var attachments: [CachedAttachment] = []

    init(name: String) {
        self.name = name
    }

    var isDeleted: Bool { deleteTime != nil }

    /// Decoded lazily and not cached: cards are rendered by SwiftUI, which already
    /// re-evaluates only when the underlying row changes.
    var cards: [ChatCard] {
        guard let cardsJSON, !isDeleted else { return [] }
        guard let decoded = try? JSONDecoder().decode([ChatCardWithID].self, from: cardsJSON) else {
            return []
        }
        return decoded.compactMap(\.card)
    }

    var hasCards: Bool { cardsJSON != nil && !isDeleted }

    /// Smart chips Chat recognised in the text — Drive files, Calendar events, Meet
    /// links. Decoded lazily, like cards.
    var richLinks: [RichLinkMetadata] {
        guard let richLinksJSON, !isDeleted else { return [] }
        guard let decoded = try? JSONDecoder().decode([ChatAnnotation].self, from: richLinksJSON)
        else { return [] }
        return decoded.compactMap(\.richLinkMetadata)
    }

    /// Text to show in the bubble. Empty when a card carries the whole message, so
    /// the bubble can be omitted entirely rather than showing a stub above the card.
    var displayText: String {
        if isDeleted { return "Message deleted" }
        if let text, !text.isEmpty { return text }
        if hasCards { return "" }
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
        if attachmentCount > 0 { return "Attachment" }
        return "Message"
    }

    /// Builds the search column from every text-bearing field, so a card message is
    /// findable by its fallback text even though it has no body of its own.
    static func searchIndex(text: String?, fallback: String?) -> String {
        [text, fallback]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    func apply(_ remote: ChatMessage) {
        text = remote.text
        fallbackText = remote.fallbackText
        searchableText = Self.searchIndex(text: remote.text, fallback: remote.fallbackText)
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
        threadName = remote.thread?.name
        isThreadReply = remote.threadReply ?? false
        attachmentCount = remote.attachment?.count ?? 0
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

    var displayName: String { contentName ?? "Attachment" }

    var isImage: Bool { contentType?.hasPrefix("image/") ?? false }

    /// Drive-hosted attachments have no media resource and must open in a browser.
    var isDownloadable: Bool { dataResourceName != nil }

    var symbol: String {
        guard let type = contentType else { return "doc" }
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        return "doc"
    }
}

@Model
final class CachedUser {
    /// Chat resource name, e.g. `users/1234567890`.
    @Attribute(.unique) var name: String
    var displayName: String?
    /// From the People API — Chat itself never supplies avatars.
    var photoURL: String?

    init(name: String) {
        self.name = name
    }
}
