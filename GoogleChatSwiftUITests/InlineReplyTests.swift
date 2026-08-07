import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// An inline reply is a quote, and a quote is the one write in this app that has to
/// name *another* message correctly. Two rules decide whether it lands at all: which
/// thread the reply is posted into, since Chat refuses a quote that crosses threads,
/// and whether the quoted message's timestamp is echoed back exactly, since it is the
/// version check Chat validates the quote against. Neither is visible in the UI, and a
/// mistake in either surfaces only as a rejected send.
@MainActor
struct InlineReplyTests {
    // MARK: - Fixtures

    private func makeStore() throws -> (ChatStore, ModelContainer) {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (ChatStore(modelContainer: container), container)
    }

    /// Decoded rather than built with the memberwise initialiser, so these stay valid
    /// as the DTOs gain fields.
    private func space(_ id: String = "A", threading: String = "THREADED_MESSAGES") throws -> ChatSpace {
        let json = """
        {"name":"spaces/\(id)","spaceType":"SPACE","spaceThreadingState":"\(threading)"}
        """
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    private func quotingMessage(
        _ id: String,
        quotes quoted: String,
        snapshotSender: String,
        snapshotText: String
    ) throws -> ChatMessage {
        let json = """
        {
          "name":"spaces/A/messages/\(id)",
          "text":"Agreed",
          "createTime":"2026-07-01T12:00:00Z",
          "sender":{"name":"users/me"},
          "thread":{"name":"spaces/A/threads/T1"},
          "threadReply":false,
          "quotedMessageMetadata":{
            "name":"spaces/A/messages/\(quoted)",
            "lastUpdateTime":"2026-07-01T11:00:00.482Z",
            "quotedMessageSnapshot":{
              "sender":"\(snapshotSender)",
              "text":"\(snapshotText)"
            }
          }
        }
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func message(_ id: String, name: String? = nil) -> CachedMessage {
        let message = CachedMessage(name: "spaces/A/messages/\(id)")
        message.text = "Original \(id)"
        message.senderName = "users/ada"
        message.senderDisplayName = name
        return message
    }

    // MARK: - Which thread the reply goes to

    /// Quoting a message that starts a thread starts a new one, matching what the web
    /// client does: the reply is a new root that happens to point at another.
    @Test func quotingARootPostsToTheMainConversation() {
        let root = message("root")
        root.threadName = "spaces/A/threads/T1"
        root.isThreadReply = false

        let target = ReplyTarget(message: root, authorName: "Ada")

        #expect(target.threadName == nil)
        #expect(target.messageName == "spaces/A/messages/root")
    }

    /// The rule that keeps the send legal. A quote may not reach across threads, so
    /// answering a reply has to happen inside the thread that reply lives in.
    @Test func quotingAReplyPostsIntoItsThread() {
        let reply = message("r1")
        reply.threadName = "spaces/A/threads/T1"
        reply.isThreadReply = true

        let target = ReplyTarget(message: reply, authorName: "Ada")

        #expect(target.threadName == "spaces/A/threads/T1")
    }

    /// In the thread pane every reply belongs to the open thread, root included — so
    /// the pane names it outright rather than letting the rule above decide.
    @Test func aThreadPaneReplyStaysInTheOpenThread() {
        let root = message("root")
        root.threadName = "spaces/A/threads/T1"
        root.isThreadReply = false

        let target = ReplyTarget(message: root, authorName: "Ada", in: "spaces/A/threads/T1")

        #expect(target.threadName == "spaces/A/threads/T1")
    }

    // MARK: - The request

    /// The timestamp goes out as the string the server produced. Re-formatting a parsed
    /// `Date` drops the fractional seconds, and the quote is checked against it.
    @Test func theRequestCarriesTheQuotedTimestampVerbatim() throws {
        let body = CreateMessageBody(
            text: "Agreed",
            thread: nil,
            attachment: nil,
            quotedMessageMetadata: QuotedMessageRef(
                name: "spaces/A/messages/root",
                lastUpdateTime: "2026-07-01T11:00:00.482391Z"
            )
        )

        let json = try #require(String(data: JSONEncoder().encode(body), encoding: .utf8))

        #expect(json.contains("\"quotedMessageMetadata\""))
        #expect(json.contains("\"lastUpdateTime\":\"2026-07-01T11:00:00.482391Z\""))
    }

    @Test func anUneditedMessageIsQuotedByItsCreateTime() throws {
        let never = try GoogleTransport.decoder.decode(
            MessageTimestamps.self,
            from: Data(#"{"createTime":"2026-07-01T11:00:00Z"}"#.utf8)
        )
        let edited = try GoogleTransport.decoder.decode(
            MessageTimestamps.self,
            from: Data(
                #"{"createTime":"2026-07-01T11:00:00Z","lastUpdateTime":"2026-07-01T11:05:00Z"}"#.utf8
            )
        )

        #expect(never.quotable == "2026-07-01T11:00:00Z")
        #expect(edited.quotable == "2026-07-01T11:05:00Z")
    }

    // MARK: - Reading a quote back

    @Test func aQuoteFromTheServerIsCached() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.mergeMessages(
            [
                try quotingMessage(
                    "m2",
                    quotes: "m1",
                    snapshotSender: "Ada Lovelace",
                    snapshotText: "Ship it?"
                )
            ],
            into: "spaces/A"
        )

        let context = ModelContext(container)
        let reply = try context.fetch(
            FetchDescriptor<CachedMessage>(
                predicate: #Predicate { $0.name == "spaces/A/messages/m2" }
            )
        ).first

        #expect(reply?.quotedMessageName == "spaces/A/messages/m1")
        #expect(reply?.quotedMessageSender == "Ada Lovelace")
        #expect(reply?.quotedMessageText == "Ship it?")
    }

    /// The cache wins over the snapshot, so a quote shows the message as it stands —
    /// including an edit that landed after it was quoted.
    @Test func aQuoteOfACachedMessageReadsFromTheCache() {
        let original = message("m1", name: "Ada Lovelace")
        original.text = "*Ship* it today"
        let reply = message("m2")
        reply.quotedMessageName = original.name
        reply.quotedMessageText = "Ship it tomorrow"
        reply.quotedMessageSender = "Ada Lovelace"

        let resolver = QuotedMessageResolver(
            messagesByName: [original.name: original],
            usersByID: [:]
        )
        let preview = resolver.preview(for: reply)

        // Markup stripped, since the quote is one line of context rather than a second
        // rendering of the message.
        #expect(preview?.text == "Ship it today")
        #expect(preview?.authorName == "Ada Lovelace")
    }

    /// A reply can quote a message older than the history backfilled for the space.
    /// Without the snapshot the quote would be an empty box.
    @Test func aQuoteOfAnUncachedMessageFallsBackToTheSnapshot() {
        let reply = message("m2")
        reply.quotedMessageName = "spaces/A/messages/ancient"
        reply.quotedMessageSender = "Ada Lovelace"
        reply.quotedMessageText = "Ship it?"

        let resolver = QuotedMessageResolver(messagesByName: [:], usersByID: [:])
        let preview = resolver.preview(for: reply)

        #expect(preview?.messageName == "spaces/A/messages/ancient")
        #expect(preview?.authorName == "Ada Lovelace")
        #expect(preview?.text == "Ship it?")
    }

    /// The snapshot's author field is documented only as an "author name", so a
    /// resource name has to be resolved rather than shown as `users/123`.
    @Test func aSnapshotAuthorGivenAsAResourceNameIsResolved() {
        let reply = message("m2")
        reply.quotedMessageName = "spaces/A/messages/ancient"
        reply.quotedMessageSender = "users/ada"
        reply.quotedMessageText = "Ship it?"

        let ada = CachedUser(name: "users/ada")
        ada.displayName = "Ada Lovelace"

        let resolver = QuotedMessageResolver(
            messagesByName: [:],
            usersByID: ["users/ada": ada]
        )

        #expect(resolver.preview(for: reply)?.authorName == "Ada Lovelace")
    }

    @Test func aMessageThatQuotesNothingHasNoPreview() {
        let resolver = QuotedMessageResolver(messagesByName: [:], usersByID: [:])
        #expect(resolver.preview(for: message("m1")) == nil)
    }

    /// A multi-line quotation collapses to one line: the transcript reads worse when a
    /// reply is taller than the message it answers.
    @Test func aQuotePreviewIsOneLine() {
        let original = message("m1")
        original.text = "First line\n\nSecond line"

        #expect(QuotedMessagePreview.line(of: original) == "First line Second line")
    }

    // MARK: - Retrying

    /// The failed placeholder is the only record of where the message was headed. A
    /// retry that dropped the quote would post a reply that answers nothing, and one
    /// that dropped the thread would post it in the wrong place — or be rejected, since
    /// the quote and the thread have to agree.
    @Test func aFailedReplyRemembersWhatItWasAnswering() async throws {
        let (store, _) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.insertPendingMessage(
            clientID: "client-1",
            text: "Agreed",
            spaceName: "spaces/A",
            senderName: "users/me",
            senderDisplayName: "Me",
            threadName: "spaces/A/threads/T1",
            quotedMessageName: "spaces/A/messages/r1"
        )
        try await store.markSendFailed(
            clientID: "client-1",
            spaceName: "spaces/A",
            reason: "offline"
        )

        let context = try await store.sendContext(for: "spaces/A/messages/client-1")

        #expect(context?.threadName == "spaces/A/threads/T1")
        #expect(context?.quotedMessageName == "spaces/A/messages/r1")
    }
}
