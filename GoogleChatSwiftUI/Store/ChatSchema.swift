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
        switch spaceType {
        case .directMessage: return "Direct message"
        case .groupChat: return "Group chat"
        default: return name
        }
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
