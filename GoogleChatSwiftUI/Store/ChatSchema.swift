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
        [CachedSpace.self, CachedMessage.self, CachedUser.self]
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

    /// Pagination cursor for backfilling this space's history. Nil once exhausted.
    var backfillPageToken: String?
    /// Whether history has been walked to the beginning.
    var backfillComplete: Bool = false
    /// When this space's messages were last reconciled against the server.
    var lastSyncedAt: Date?

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

    func apply(_ remote: ChatSpace) {
        displayName = remote.displayName
        spaceTypeRaw = remote.spaceType?.rawValue
        spaceDescription = remote.spaceDetails?.description
        createTime = remote.createTime
        lastActiveTime = remote.lastActiveTime
        memberCount = remote.membershipCount?.joinedDirectHumanUserCount
    }
}

@Model
final class CachedMessage {
    /// Chat resource name, e.g. `spaces/AAAA/messages/BBBB`.
    /// This is the dedupe key that makes pagination and the event stream converge.
    @Attribute(.unique) var name: String

    var text: String?
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

    var space: CachedSpace?

    init(name: String) {
        self.name = name
    }

    var isDeleted: Bool { deleteTime != nil }

    var displayText: String {
        if isDeleted { return "Message deleted" }
        if let text, !text.isEmpty { return text }
        if attachmentCount > 0 { return "Attachment" }
        return "Card message"
    }

    func apply(_ remote: ChatMessage) {
        text = remote.text
        createTime = remote.createTime
        lastUpdateTime = remote.lastUpdateTime
        deleteTime = remote.deleteTime
        senderName = remote.sender?.name
        senderDisplayName = remote.sender?.displayName
        threadName = remote.thread?.name
        isThreadReply = remote.threadReply ?? false
        attachmentCount = remote.attachment?.count ?? 0
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
