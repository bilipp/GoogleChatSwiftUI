import Foundation

// Wire models for Google Chat REST v1. Field names mirror the API exactly; the
// decoder applies `.convertFromSnakeCase`-free explicit keys because Chat uses
// lowerCamelCase on the wire already.

nonisolated struct ChatUser: Decodable, Sendable, Hashable, Identifiable {
    enum UserType: String, Decodable, Sendable {
        case unspecified = "TYPE_UNSPECIFIED"
        case human = "HUMAN"
        case bot = "BOT"
    }

    /// Resource name, e.g. `users/1234567890`.
    let name: String?
    let displayName: String?
    let domainId: String?
    let type: UserType?
    let isAnonymous: Bool?

    var id: String { name ?? UUID().uuidString }

    /// Chat omits `displayName` for some senders (notably in DMs where the caller
    /// already knows the peer), so callers need a fallback.
    var resolvedName: String { displayName ?? "Unknown" }
}

nonisolated struct ChatSpace: Decodable, Sendable, Hashable, Identifiable {
    enum SpaceType: String, Decodable, Sendable {
        case unspecified = "SPACE_TYPE_UNSPECIFIED"
        case space = "SPACE"
        case groupChat = "GROUP_CHAT"
        case directMessage = "DIRECT_MESSAGE"
    }

    nonisolated struct Details: Decodable, Sendable, Hashable {
        let description: String?
        let guidelines: String?
    }

    /// Resource name, e.g. `spaces/AAAA1111`.
    let name: String
    let spaceType: SpaceType?
    /// `THREADED_MESSAGES`, `GROUPED_MESSAGES`, or `UNTHREADED_MESSAGES`. Only the
    /// first keeps replies out of the main flow.
    let spaceThreadingState: String?
    let singleUserBotDm: Bool?
    let displayName: String?
    let spaceDetails: Details?
    let createTime: Date?
    let lastActiveTime: Date?
    let membershipCount: MembershipCount?
    let spaceUri: String?

    nonisolated struct MembershipCount: Decodable, Sendable, Hashable {
        let joinedDirectHumanUserCount: Int?
        let joinedGroupCount: Int?
    }

    var id: String { name }

    /// DMs and unnamed group chats have no `displayName`; the real Google Chat client
    /// substitutes the other members' names, which requires a separate members call.
    /// Phase 4 does that — until then this is an honest placeholder.
    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        switch spaceType {
        case .directMessage: return "Direct message"
        case .groupChat: return "Group chat"
        default: return name
        }
    }
}

nonisolated struct ChatThread: Decodable, Sendable, Hashable {
    let name: String?
    let threadKey: String?
}

nonisolated struct ChatAttachment: Decodable, Sendable, Hashable {
    /// Pointer used by `media.download`; distinct from the user-facing `downloadUri`.
    nonisolated struct DataRef: Decodable, Sendable, Hashable {
        let resourceName: String?
    }

    let name: String?
    let contentName: String?
    let contentType: String?
    let thumbnailUri: String?
    let downloadUri: String?
    let attachmentDataRef: DataRef?
    let source: String?
}

nonisolated struct ChatEmoji: Codable, Sendable, Hashable {
    nonisolated struct CustomEmoji: Codable, Sendable, Hashable {
        let uid: String?
    }
    let unicode: String?
    let customEmoji: CustomEmoji?

    /// Custom emoji have no unicode representation, so they degrade to a marker
    /// rather than rendering as nothing.
    var display: String { unicode ?? "🧩" }
}

nonisolated struct EmojiReactionSummary: Decodable, Sendable, Hashable {
    let emoji: ChatEmoji?
    let reactionCount: Int?
}

nonisolated struct ChatReaction: Decodable, Sendable, Hashable {
    /// Resource name, e.g. `spaces/A/messages/B/reactions/C` — needed to delete.
    let name: String?
    let user: ChatUser?
    let emoji: ChatEmoji?
}

nonisolated struct ListReactionsResponse: Decodable, Sendable {
    let reactions: [ChatReaction]?
    let nextPageToken: String?
}

/// Structured spans Chat attaches to message text: mentions, slash commands, links.
nonisolated struct ChatAnnotation: Decodable, Sendable, Hashable {
    nonisolated struct UserMention: Decodable, Sendable, Hashable {
        let user: ChatUser?
        /// `ADD` when the user was added to the thread, `MENTION` otherwise.
        let type: String?
    }

    let type: String?
    let startIndex: Int?
    let length: Int?
    let userMention: UserMention?
}

nonisolated struct ChatMessage: Decodable, Sendable, Hashable, Identifiable {
    /// Resource name, e.g. `spaces/AAAA/messages/BBBB`.
    let name: String
    let sender: ChatUser?
    let createTime: Date?
    let lastUpdateTime: Date?
    let deleteTime: Date?
    let text: String?
    let formattedText: String?
    /// Plain-text stand-in Chat supplies for card messages, used in notifications.
    let fallbackText: String?
    let thread: ChatThread?
    let threadReply: Bool?
    let attachment: [ChatAttachment]?
    let emojiReactionSummaries: [EmojiReactionSummary]?
    let annotations: [ChatAnnotation]?
    let cardsV2: [ChatCardWithID]?

    var id: String { name }
    var isDeleted: Bool { deleteTime != nil }

    var hasCards: Bool { cardsV2?.isEmpty == false }

    /// Fallback text for a message with no body of its own.
    ///
    /// Card messages usually carry no `text` at all; when cards render, the bubble
    /// shows them instead of this, and `fallbackText` is what Chat itself supplies
    /// for notification surfaces.
    var displayText: String {
        if isDeleted { return "Message deleted" }
        if let text, !text.isEmpty { return text }
        if let fallbackText, !fallbackText.isEmpty { return fallbackText }
        if attachment?.isEmpty == false { return "Attachment" }
        if hasCards { return "Card message" }
        return ""
    }
}

// MARK: - List envelopes

nonisolated struct ListSpacesResponse: Decodable, Sendable {
    let spaces: [ChatSpace]?
    let nextPageToken: String?
}

nonisolated struct ListMessagesResponse: Decodable, Sendable {
    let messages: [ChatMessage]?
    let nextPageToken: String?
}

nonisolated struct ChatMembership: Decodable, Sendable, Hashable {
    /// Resource name, e.g. `spaces/AAAA/members/BBBB`.
    let name: String?
    let state: String?
    let role: String?
    let member: ChatUser?

    var isJoined: Bool { state == "JOINED" }
}

nonisolated struct ListMembersResponse: Decodable, Sendable {
    let memberships: [ChatMembership]?
    let nextPageToken: String?
}
