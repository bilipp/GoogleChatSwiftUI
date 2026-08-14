import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// A forward and a reply arrive in the same field, `quotedMessageMetadata`, and are told apart
/// by one string. Everything else about them differs: a reply points at a message in the
/// conversation you are reading, and a forward carries a message out of one you may have no
/// access to at all — so the copy that came with it is the only copy there will ever be.
///
/// These tests pin the two apart at every layer they could be confused: what gets stored, what
/// the resolver builds, and what the transcript draws.
@MainActor
struct ForwardedMessageTests {
    // MARK: - Fixtures

    private func makeStore() throws -> (ChatStore, ModelContainer) {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (ChatStore(modelContainer: container), container)
    }

    private func space(_ id: String = "A") throws -> ChatSpace {
        let json = """
        {"name":"spaces/\(id)","spaceType":"SPACE","spaceThreadingState":"THREADED_MESSAGES"}
        """
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    /// Decoded rather than built with the memberwise initialiser, so these stay valid as the
    /// DTOs gain fields — and so the shape under test is the shape Chat actually sends.
    ///
    /// - Parameter comment: what the forwarder typed above what they sent on. Empty for a
    ///   forward passed along with nothing added, which is the common case.
    private func forwardingMessage(
        _ id: String = "m2",
        comment: String = "FYI",
        quoteType: String = "FORWARD",
        snapshot: String = Self.fullSnapshot,
        source: String = #"{"space":"spaces/B","spaceDisplayName":"Univcc Rollout"}"#
    ) throws -> ChatMessage {
        let json = """
        {
          "name":"spaces/A/messages/\(id).\(id)",
          "text":"\(comment)",
          "createTime":"2026-08-14T07:20:30Z",
          "sender":{"name":"users/julia","type":"HUMAN"},
          "thread":{"name":"spaces/A/threads/\(id)"},
          "threadReply":false,
          "quotedMessageMetadata":{
            "name":"spaces/B/messages/o1.o1",
            "lastUpdateTime":"2026-08-01T09:00:00.482Z",
            "quoteType":"\(quoteType)",
            "quotedMessageSnapshot":\(snapshot),
            "forwardedMetadata":\(source)
          }
        }
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    /// Everything Chat populates for a `FORWARD`: the plain body, the formatted one, the
    /// annotations parsed out of it, and copies of the original's attachment metadata.
    private static let fullSnapshot = """
    {
      "sender":"Ada Lovelace",
      "text":"Ship the parser? @Grace Hopper",
      "formattedText":"*Ship* the parser? <users/grace>",
      "annotations":[
        {
          "type":"USER_MENTION",
          "startIndex":18,
          "length":13,
          "userMention":{"user":{"name":"users/grace","type":"HUMAN"},"type":"MENTION"}
        }
      ],
      "attachments":[
        {
          "name":"spaces/B/messages/o1.o1/attachments/att1",
          "contentName":"Screenshot.jpg",
          "contentType":"image/jpeg",
          "attachmentDataRef":{"resourceName":"spaces/B/messages/o1.o1/attachments/att1"},
          "source":"UPLOADED_CONTENT"
        }
      ]
    }
    """

    /// What a `REPLY`'s snapshot carries, which is the two fields a line of context needs.
    private static let replySnapshot = #"{"sender":"Ada Lovelace","text":"Ship the parser?"}"#

    private func stored(
        _ remote: ChatMessage,
        in store: ChatStore,
        container: ModelContainer
    ) async throws -> CachedMessage {
        try await store.upsertSpaces([try space()])
        try await store.mergeMessages([remote], into: "spaces/A")
        let context = ModelContext(container)
        let name = remote.name
        return try #require(
            try context.fetch(
                FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.name == name })
            ).first
        )
    }

    private func grace() -> CachedUser {
        let user = CachedUser(name: "users/grace")
        user.displayName = "Grace Hopper"
        return user
    }

    // MARK: - Telling the two quote types apart

    @Test func aForwardIsRecognisedByItsQuoteType() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(try forwardingMessage(), in: store, container: container)

        #expect(cached.isForwarded)
        #expect(cached.quoteTypeRaw == "FORWARD")
        #expect(cached.quotedMessageName == "spaces/B/messages/o1.o1")
    }

    /// Chat omits `quoteType` for a reply and documents the omission as meaning `REPLY`, so
    /// absence must not read as "might be a forward" — every inline reply in the cache from
    /// before this field existed has nothing in that column.
    @Test func aReplyWithNoQuoteTypeIsNotAForward() async throws {
        let (store, container) = try makeStore()
        let json = """
        {
          "name":"spaces/A/messages/r1.r1",
          "text":"Agreed",
          "createTime":"2026-08-14T07:20:30Z",
          "sender":{"name":"users/julia"},
          "quotedMessageMetadata":{
            "name":"spaces/A/messages/o1.o1",
            "lastUpdateTime":"2026-08-01T09:00:00.482Z",
            "quotedMessageSnapshot":\(Self.replySnapshot)
          }
        }
        """
        let remote = try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
        let cached = try await stored(remote, in: store, container: container)

        #expect(!cached.isForwarded)
        #expect(cached.quoteTypeRaw == nil)
        #expect(cached.quotedMessageName == "spaces/A/messages/o1.o1")
    }

    @Test func anExplicitReplyQuoteTypeIsNotAForward() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(
            try forwardingMessage(quoteType: "REPLY", snapshot: Self.replySnapshot),
            in: store,
            container: container
        )

        #expect(!cached.isForwarded)
    }

    /// An unknown quote type must degrade to "not a forward" rather than failing the decode of
    /// the whole message — which is why the field is a raw string and not an enum.
    @Test func anUnknownQuoteTypeStillDecodesTheMessage() throws {
        let remote = try forwardingMessage(quoteType: "SOMETHING_NEW")

        #expect(remote.text == "FYI")
        #expect(remote.quotedMessageMetadata?.isForward == false)
    }

    // MARK: - What gets stored

    @Test func theForwardedSnapshotIsStoredInFull() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(try forwardingMessage(), in: store, container: container)

        #expect(cached.forwardedFromSpace == "spaces/B")
        #expect(cached.forwardedFromSpaceTitle == "Univcc Rollout")
        #expect(cached.quotedMessageSender == "Ada Lovelace")
        #expect(cached.quotedMessageText == "Ship the parser? @Grace Hopper")
        #expect(cached.quotedMessageFormattedText == "*Ship* the parser? <users/grace>")
        #expect(cached.quotedAttachments.count == 1)
        #expect(cached.quotedAttachments.first?.contentName == "Screenshot.jpg")
        #expect(cached.quotedAnnotations.count == 1)
    }

    /// A forwarded attachment names an attachment belonging to a message in another space. If
    /// those became ``CachedAttachment`` rows they would collide on the unique resource name
    /// with the original's own row — and the row would be handed to whichever message was
    /// written last, moving an attachment off the message it belongs to.
    @Test func forwardedAttachmentsDoNotBecomeRowsOnTheForwardingMessage() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(try forwardingMessage(), in: store, container: container)

        #expect(cached.attachments.isEmpty)
        #expect(cached.attachmentCount == 0)
        #expect(cached.quotedAttachments.count == 1)
    }

    /// An edit that removes the forward — or any later payload that arrives without the
    /// metadata — has to clear the columns, or the block would outlive what put it there.
    @Test func aPayloadWithoutTheMetadataClearsTheForward() async throws {
        let (store, container) = try makeStore()
        _ = try await stored(try forwardingMessage(), in: store, container: container)

        let plain = try GoogleTransport.decoder.decode(
            ChatMessage.self,
            from: Data(
                """
                {"name":"spaces/A/messages/m2.m2","text":"FYI",
                 "createTime":"2026-08-14T07:20:30Z","sender":{"name":"users/julia"}}
                """.utf8
            )
        )
        let cached = try await stored(plain, in: store, container: container)

        #expect(!cached.isForwarded)
        #expect(cached.forwardedFromSpace == nil)
        #expect(cached.quotedAttachmentsJSON == nil)
        #expect(cached.quotedMessageFormattedText == nil)
    }

    // MARK: - What the transcript draws

    @Test func aForwardResolvesToItsOwnKindOfContent() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(try forwardingMessage(), in: store, container: container)

        let resolver = QuotedMessageResolver(
            messagesByName: [:],
            usersByID: ["users/grace": grace()]
        )
        let forwarded = try #require(resolver.content(for: cached)?.forwarded)

        #expect(resolver.content(for: cached)?.replyPreview == nil)
        #expect(forwarded.messageName == "spaces/B/messages/o1.o1")
        #expect(forwarded.sourceSpaceName == "spaces/B")
        #expect(forwarded.sourceTitle == "Univcc Rollout")
        #expect(forwarded.authorName == "Ada Lovelace")
        #expect(forwarded.attachments.first?.displayName == "Screenshot.jpg")
        #expect(forwarded.attachments.first?.isDownloadable == true)
    }

    /// Chat sends the snapshot's `sender` empty often enough — every inline reply in this
    /// account's own cache has it blank, despite the field being documented as populated for
    /// both quote types — that the author has to be *absent* rather than named "Unknown". The
    /// header already says where the message came from.
    @Test func aForwardWithNoNamedAuthorNamesNobody() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(
            try forwardingMessage(snapshot: #"{"sender":"","text":"Ship the parser?"}"#),
            in: store,
            container: container
        )

        let resolver = QuotedMessageResolver(messagesByName: [:], usersByID: [:])
        let forwarded = try #require(resolver.content(for: cached)?.forwarded)

        #expect(forwarded.authorName == nil)
        #expect(forwarded.body.text == "Ship the parser?")
    }

    /// The formatted copy is used when every mention in it can be named, so the forwarded body
    /// keeps its markup — the same rule every other body goes through.
    @Test func aForwardedBodyKeepsItsFormattingWhenTheMentionIsKnown() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(try forwardingMessage(), in: store, container: container)

        let resolver = QuotedMessageResolver(
            messagesByName: [:],
            usersByID: ["users/grace": grace()]
        )
        let forwarded = try #require(resolver.content(for: cached)?.forwarded)

        #expect(forwarded.body.source == .formatted)
        #expect(forwarded.body.text == "*Ship* the parser? <users/grace>")
        #expect(forwarded.mentions == ["users/grace": "Grace Hopper"])
    }

    /// And falls back to the plain copy when it cannot. This is the common case for a forward:
    /// the people mentioned in it were talking in a space this account may not be in, so the
    /// directory has had no reason to answer for them. The plain body already spells the name
    /// out, which is why the fallback loses nothing but the bold.
    @Test func anUnnameableMentionFallsBackToThePlainBody() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(try forwardingMessage(), in: store, container: container)

        let resolver = QuotedMessageResolver(messagesByName: [:], usersByID: [:])
        let forwarded = try #require(resolver.content(for: cached)?.forwarded)

        #expect(forwarded.body.source == .plain)
        #expect(forwarded.body.text == "Ship the parser? @Grace Hopper")
        #expect(forwarded.mentions.isEmpty)
    }

    /// The opposite of what a reply does. A reply prefers the cache so a quote reflects an edit
    /// that landed afterwards; a forward must not, or the same forwarded message would read
    /// differently depending on which spaces this account happens to have cached — and it would
    /// show text the forwarder never passed on.
    @Test func aForwardReadsTheSnapshotEvenWhenTheOriginalIsCached() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(try forwardingMessage(), in: store, container: container)

        let original = CachedMessage(name: "spaces/B/messages/o1.o1")
        original.text = "Actually, hold the parser"
        original.senderName = "users/ada"

        let resolver = QuotedMessageResolver(
            messagesByName: [original.name: original],
            usersByID: [:]
        )
        let forwarded = try #require(resolver.content(for: cached)?.forwarded)

        #expect(forwarded.body.text == "Ship the parser? @Grace Hopper")
    }

    /// A forward Chat described without a snapshot would otherwise draw an empty bordered box.
    @Test func aForwardWithNothingInItIsNotDrawn() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(
            try forwardingMessage(comment: "Look at this", snapshot: "{}"),
            in: store,
            container: container
        )

        #expect(cached.isForwarded)
        let resolver = QuotedMessageResolver(messagesByName: [:], usersByID: [:])
        #expect(resolver.content(for: cached) == nil)
    }

    /// A forward passed on without a comment has no text of its own, and the bubble is omitted
    /// entirely — the block beneath is the message. "Attachment" would be describing the block.
    @Test func aForwardWithNoCommentHasNoBubbleText() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(
            try forwardingMessage(comment: ""),
            in: store,
            container: container
        )

        #expect(cached.displayText.isEmpty)
    }

    /// The one surface that cannot render the block: a notification banner or the menu bar,
    /// where "Message" would be all a forward ever said.
    @Test func aForwardWithNoCommentStillSummarisesInANotification() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(
            try forwardingMessage(comment: ""),
            in: store,
            container: container
        )

        #expect(cached.summaryText == "Forwarded: Ship the parser? @Grace Hopper")
    }

    // MARK: - Search

    /// A forward with no comment has no text of its own, so without this it would be findable
    /// by nothing at all.
    @Test func aForwardedBodyIsSearchable() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(
            try forwardingMessage(comment: ""),
            in: store,
            container: container
        )

        #expect(cached.searchableText.contains("ship the parser"))
    }

    /// A reply's quoted text is deliberately not indexed: it belongs to the message being
    /// answered, and indexing it would make every reply a hit for that message's words.
    @Test func aRepliedToBodyIsNotSearchable() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(
            try forwardingMessage(comment: "Agreed", quoteType: "REPLY"),
            in: store,
            container: container
        )

        #expect(cached.searchableText == "agreed")
    }

    // MARK: - Getting to the original

    /// The source is named by resource names, never by a URL — Chat says which space a forward
    /// came out of but never whether it is a room or a DM, and the two take different paths.
    @Test func theOriginalIsAddressedByResourceName() {
        let link = ChatDeepLink(
            spaceName: "spaces/B",
            messageName: "spaces/B/messages/o1.o1"
        )

        #expect(link.spaceName == "spaces/B")
        #expect(link.messageName == "spaces/B/messages/o1.o1")
        #expect(link.threadName == nil)
    }
}
