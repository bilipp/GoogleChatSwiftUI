import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// Where a followed `chat.google.com` link actually lands, resolved against the cache.
///
/// The case these exist for: a reply in a threaded space is nowhere in the transcript, so
/// the link resolves to its thread — and the reply has to travel with the thread. Without
/// it the pane opens on its newest message and the link, having done everything except the
/// one thing it promised, has still not shown anybody the message it named.
struct ChatLinkDestinationTests {
    private func makeStore() throws -> ChatStore {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ChatStore(modelContainer: container)
    }

    /// Decoded rather than built with the memberwise initialiser, so these stay valid as
    /// the DTOs gain fields.
    private func space(threading: String) throws -> ChatSpace {
        let json = """
        {"name":"spaces/A","spaceType":"SPACE","spaceThreadingState":"\(threading)"}
        """
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    private func message(_ id: String, thread: String, isReply: Bool) throws -> ChatMessage {
        let json = """
        {
          "name":"spaces/A/messages/\(id)",
          "text":"\(id)",
          "createTime":"2026-07-01T11:00:00Z",
          "sender":{"name":"users/other"},
          "thread":{"name":"spaces/A/threads/\(thread)"},
          "threadReply":\(isReply)
        }
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func link(_ text: String) throws -> ChatDeepLink {
        let url = try #require(URL(string: text))
        return try #require(ChatDeepLink(url: url))
    }

    @Test
    func aReplyInAThreadedSpaceTakesItsReplyWithIt() async throws {
        let store = try makeStore()
        try await store.upsertSpaces([space(threading: "THREADED_MESSAGES")])
        try await store.mergeMessages(
            [
                try message("T1.root", thread: "T1", isReply: false),
                try message("T1.r1", thread: "T1", isReply: true),
            ],
            into: "spaces/A"
        )

        let destination = try await store.destination(of: link("https://chat.google.com/room/A/T1/r1"))

        #expect(destination == .thread("spaces/A/threads/T1", message: "spaces/A/messages/T1.r1"))
    }

    /// A link naming a thread and nothing in it. There is a place to go and no message to
    /// mark once it is open, which is the difference the associated value carries.
    @Test
    func aThreadWithNoMessageNamedCarriesNothing() async throws {
        let store = try makeStore()
        try await store.upsertSpaces([space(threading: "THREADED_MESSAGES")])

        let destination = try await store.destination(of: link("https://chat.google.com/room/A/T1"))

        #expect(destination == .thread("spaces/A/threads/T1", message: nil))
    }

    /// Where replies are in the transcript, the transcript is where the link goes — the
    /// thread pane is not even open in a grouped space.
    @Test
    func aReplyInAGroupedSpaceStaysInTheTranscript() async throws {
        let store = try makeStore()
        try await store.upsertSpaces([space(threading: "GROUPED_MESSAGES")])
        try await store.mergeMessages(
            [try message("T1.r1", thread: "T1", isReply: true)],
            into: "spaces/A"
        )

        let destination = try await store.destination(of: link("https://chat.google.com/room/A/T1/r1"))

        #expect(destination == .message("spaces/A/messages/T1.r1"))
    }

    /// The message is real, the history simply does not reach back to it yet. Told apart
    /// from a message that resolves, because this is the one the reader has to be told
    /// about rather than scrolled to.
    @Test
    func aMessageTheCacheHasNotReachedIsSaidToBeMissing() async throws {
        let store = try makeStore()
        try await store.upsertSpaces([space(threading: "THREADED_MESSAGES")])

        let destination = try await store.destination(of: link("https://chat.google.com/room/A/T1/r1"))

        #expect(destination == .uncachedMessage)
    }
}
