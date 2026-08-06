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
    let name: String?
    let contentName: String?
    let contentType: String?
    let thumbnailUri: String?
    let downloadUri: String?
}

nonisolated struct EmojiReactionSummary: Decodable, Sendable, Hashable {
    nonisolated struct Emoji: Decodable, Sendable, Hashable {
        let unicode: String?
    }
    let emoji: Emoji?
    let reactionCount: Int?
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
    let thread: ChatThread?
    let threadReply: Bool?
    let attachment: [ChatAttachment]?
    let emojiReactionSummaries: [EmojiReactionSummary]?

    var id: String { name }
    var isDeleted: Bool { deleteTime != nil }

    /// Bot card messages carry no `text`. Rendering cards properly is Phase 7 work;
    /// until then they need to read as something other than an empty bubble.
    var displayText: String {
        if isDeleted { return "Message deleted" }
        if let text, !text.isEmpty { return text }
        if attachment?.isEmpty == false { return "Attachment" }
        return "Card message"
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
