import Foundation

// Wire models for Google Chat REST v1. Field names mirror the API exactly; the
// decoder applies `.convertFromSnakeCase`-free explicit keys because Chat uses
// lowerCamelCase on the wire already.

nonisolated struct ChatUser: Codable, Sendable, Hashable, Identifiable {
    enum UserType: String, Codable, Sendable {
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
    enum SpaceType: String, Decodable, Sendable, CaseIterable {
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

/// Encodable as well as decodable because a forwarded message's attachments are stored
/// as a JSON blob on the row that forwarded them — see
/// ``CachedMessage/quotedAttachmentsJSON``. Nothing sends one of these to Chat; the
/// upload path uses ``CreateMessageBody/AttachmentRef`` and its ``DataRef`` instead.
nonisolated struct ChatAttachment: Codable, Sendable, Hashable {
    /// Pointer used by `media.download`, and the token returned by `media.upload`.
    /// Codable in both directions because an upload's ref is sent straight back in
    /// the message create request.
    nonisolated struct DataRef: Codable, Sendable, Hashable {
        var resourceName: String?
        /// Returned by `media.upload`; the only field a create request needs.
        var attachmentUploadToken: String?
    }

    let name: String?
    let contentName: String?
    let contentType: String?
    let thumbnailUri: String?
    let downloadUri: String?
    let attachmentDataRef: DataRef?
    let source: String?
}

/// A GIF attached to a message.
///
/// Read-only, and not for want of a field to write: Chat documents `attachedGifs` as
/// output only, so a GIF chosen in the web client's picker arrives here as a URL and there
/// is no way to send one back the same way. Attaching a `.gif` *file* is a different thing
/// entirely and goes through ``ChatAttachment``.
///
/// The URI is public and unauthenticated — Google serves these from Tenor's CDN — so
/// unlike an attachment it needs no credentialed fetch.
///
/// Absent from `QuotedMessageSnapshot`, which carries `attachments` but not this, so a
/// forwarded GIF arrives as a forward of nothing. Not an omission here: there is no field
/// to read it out of.
nonisolated struct AttachedGif: Decodable, Sendable, Hashable {
    /// The URL hosting the GIF image.
    let uri: String?
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
nonisolated struct ChatAnnotation: Codable, Sendable, Hashable {
    nonisolated struct UserMention: Codable, Sendable, Hashable {
        let user: ChatUser?
        /// `ADD` when the user was added to the thread, `MENTION` otherwise.
        let type: String?
    }

    let type: String?
    let startIndex: Int?
    let length: Int?
    let userMention: UserMention?
    let richLinkMetadata: RichLinkMetadata?
}

/// A smart chip: a Drive file, Calendar event, Meet space, Chat space, or Gmail
/// message that Chat recognised in the message text.
nonisolated struct RichLinkMetadata: Codable, Sendable, Hashable {
    nonisolated struct DriveLinkData: Codable, Sendable, Hashable {
        nonisolated struct DriveDataRef: Codable, Sendable, Hashable {
            let driveFileId: String?
        }
        let driveDataRef: DriveDataRef?
        let mimeType: String?
    }

    nonisolated struct ChatSpaceLinkData: Codable, Sendable, Hashable {
        let space: String?
        let thread: String?
        let message: String?
    }

    nonisolated struct CalendarEventLinkData: Codable, Sendable, Hashable {
        let calendarId: String?
        let eventId: String?
    }

    nonisolated struct MeetSpaceLinkData: Codable, Sendable, Hashable {
        let meetingCode: String?
        /// `MEETING` or `HUDDLE`.
        let type: String?
        let huddleStatus: String?
    }

    let uri: String?
    /// `DRIVE_FILE`, `CHAT_SPACE`, `GMAIL_MESSAGE`, `MEET_SPACE`, `CALENDAR_EVENT`.
    let richLinkType: String?
    let driveLinkData: DriveLinkData?
    let chatSpaceLinkData: ChatSpaceLinkData?
    let calendarEventLinkData: CalendarEventLinkData?
    let meetSpaceLinkData: MeetSpaceLinkData?
}

/// Where a forwarded message came from.
///
/// The source conversation is named as it looked *at the time of forwarding*, which is
/// the only name available for it: a forward can cross out of a space the reader is not
/// a member of, and then nothing else in this app can say what that space is called.
nonisolated struct ForwardedMetadata: Decodable, Sendable, Hashable {
    /// Resource name of the source space, e.g. `spaces/AAAA1111`.
    let space: String?
    /// For a space, its name. For a DM, the other participant's name. For a group chat,
    /// a name generated from up to five members' first names.
    let spaceDisplayName: String?
}

/// The message another message quotes — Chat's inline reply, and its forward.
///
/// One field carries both, told apart by ``quoteType``. A `REPLY` is what the web client
/// sets when you answer one message in the main conversation rather than opening a
/// thread; a `FORWARD` is what it sets when you send a message on to somewhere else, and
/// may reach across spaces or across threads, which a reply may not.
///
/// `name` and `lastUpdateTime` are the pair a create request has to carry; everything
/// else is the server's own account of what was quoted, and is filled in on read only.
nonisolated struct QuotedMessageMetadata: Decodable, Sendable, Hashable {
    /// What the quoted message said when it was quoted.
    ///
    /// Worth keeping even though the app caches messages of its own: a reply can quote
    /// something older than the history that has been backfilled, and then this is the
    /// only description of it available. For a forward it is more than a fallback — it is
    /// the *whole* of the forwarded message, since the original lives in a conversation
    /// the reader may have no access to at all.
    ///
    /// Which is why four of these five fields are documented as `FORWARD`-only: a reply
    /// needs one line of context, and a forward needs the message.
    nonisolated struct Snapshot: Decodable, Sendable, Hashable {
        /// The quoted message's author. Documented as an author *name*, without saying
        /// whether that means a display name or a `users/123` resource name — so
        /// callers have to be ready for either.
        let sender: String?
        let text: String?
        /// The same body with its markup still in it — see ``ChatTextSource``.
        let formattedText: String?
        /// Mentions and rich links parsed out of the snapshot's own body. Needed because
        /// `formattedText` names mentioned people as `<users/123>` and nothing else here
        /// says who they are.
        let annotations: [ChatAnnotation]?
        /// Copies of the original's attachment metadata.
        let attachments: [ChatAttachment]?
    }

    let name: String?
    let lastUpdateTime: Date?
    /// `REPLY` or `FORWARD`.
    ///
    /// Left as the raw string rather than modelled as an enum, like `richLinkType` and
    /// `spaceThreadingState` and unlike `Space.spaceType`: a `RawRepresentable` enum
    /// throws on a value it does not know, and the throw would fail the decode of the
    /// whole *message*, so a fourth quote type would not degrade — it would make messages
    /// disappear.
    ///
    /// Chat documents the field as defaulting to `REPLY` when unset, on read as well as
    /// on write, so absence means reply rather than "not known".
    let quoteType: String?
    let quotedMessageSnapshot: Snapshot?
    /// The source conversation. Populated for forwards only.
    let forwardedMetadata: ForwardedMetadata?

    static let forwardQuoteType = "FORWARD"

    var isForward: Bool { quoteType == Self.forwardQuoteType }
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
    /// GIFs picked from Chat's own picker, which are not attachments — see ``AttachedGif``.
    let attachedGifs: [AttachedGif]?
    let emojiReactionSummaries: [EmojiReactionSummary]?
    let annotations: [ChatAnnotation]?
    let cardsV2: [ChatCardWithID]?
    /// Set when this message is an inline reply to another one.
    let quotedMessageMetadata: QuotedMessageMetadata?

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
        if attachedGifs?.isEmpty == false { return "GIF" }
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
