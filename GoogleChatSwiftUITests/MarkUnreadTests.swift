import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// Marking a conversation unread is read state run backwards: the mark goes behind the
/// newest message instead of ahead of it. Chat has no unread flag to set, only this
/// timestamp, so everything the feature does rests on picking the right one — which is
/// what these cover.
struct MarkUnreadTests {
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
    private func threadedSpace(lastActive: String? = nil) throws -> ChatSpace {
        let active = lastActive.map { ",\"lastActiveTime\":\"\($0)\"" } ?? ""
        let json = """
        {"name":"spaces/A","spaceType":"SPACE","spaceThreadingState":"THREADED_MESSAGES"\(active)}
        """
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    private func message(
        _ id: String,
        thread: String,
        at timestamp: String,
        isReply: Bool,
        sender: String = "users/other"
    ) throws -> ChatMessage {
        let json = """
        {
          "name":"spaces/A/messages/\(id)",
          "text":"\(id)",
          "createTime":"\(timestamp)",
          "sender":{"name":"\(sender)"},
          "thread":{"name":"spaces/A/threads/\(thread)"},
          "threadReply":\(isReply)
        }
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func space(in container: ModelContainer) throws -> CachedSpace? {
        let context = ModelContext(container)
        return try context.fetch(
            FetchDescriptor<CachedSpace>(predicate: #Predicate { $0.name == "spaces/A" })
        ).first
    }

    private func thread(in container: ModelContainer) throws -> CachedThread? {
        let context = ModelContext(container)
        return try context.fetch(
            FetchDescriptor<CachedThread>(predicate: #Predicate { $0.name == "spaces/A/threads/T1" })
        ).first
    }

    private func date(_ iso: String) throws -> Date {
        try Date(iso, strategy: .iso8601)
    }

    /// Two top-level messages, the last at 13:00, all of it read.
    private func readSpace() async throws -> (ChatStore, ModelContainer) {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try threadedSpace()])
        try await store.mergeMessages(
            [
                try message("m1", thread: "T1", at: "2026-07-01T11:00:00Z", isReply: false),
                try message("m2", thread: "T2", at: "2026-07-01T13:00:00Z", isReply: false),
            ],
            into: "spaces/A"
        )
        try await store.markReadLocally(spaceName: "spaces/A", at: try date("2026-07-01T14:00:00Z"))
        return (store, container)
    }

    /// A second behind the newest message, not a hair behind it: the mark is sent to
    /// Chat as ISO-8601 with second precision, and anything finer is truncated back
    /// onto the message's own timestamp — which is a space that is still read.
    @Test func theMarkLandsAFullSecondBehindTheNewestMessage() async throws {
        let (store, _) = try await readSpace()

        let mark = try await store.unreadMark(spaceName: "spaces/A")

        #expect(mark == (try date("2026-07-01T12:59:59Z")))
    }

    /// One thing to come back to — the message it was marked unread for — rather than
    /// the whole conversation resurrected.
    @Test func markingUnreadLeavesExactlyTheNewestMessageUnread() async throws {
        let (store, container) = try await readSpace()

        let mark = try #require(try await store.unreadMark(spaceName: "spaces/A"))
        try await store.markUnreadLocally(spaceName: "spaces/A", at: mark)

        let space = try space(in: container)
        #expect(space?.unreadCount == 1)
        #expect(space?.isUnread == true)
        #expect(try await store.unreadSpaceNames() == ["spaces/A"])
        #expect(try await store.totalUnread() == 1)
    }

    /// It has to survive the round trip, or the sidebar keeps a badge for a
    /// conversation the user has since opened.
    @Test func openingItAfterwardsClearsItAgain() async throws {
        let (store, container) = try await readSpace()
        let mark = try #require(try await store.unreadMark(spaceName: "spaces/A"))
        try await store.markUnreadLocally(spaceName: "spaces/A", at: mark)

        try await store.markReadLocally(spaceName: "spaces/A", at: Date())

        #expect(try space(in: container)?.isUnread == false)
        #expect(try await store.totalUnread() == 0)
    }

    /// Chat's space read state does not speak for thread replies, and neither does
    /// this. A thread already read stays read, and the badge counts the reply it
    /// re-exposes exactly once.
    @Test func threadReadMarksAreLeftWhereTheyAre() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try threadedSpace()])
        try await store.mergeMessages(
            [
                try message("root", thread: "T1", at: "2026-07-01T11:00:00Z", isReply: false),
                try message("r1", thread: "T1", at: "2026-07-01T13:00:00Z", isReply: true),
            ],
            into: "spaces/A"
        )
        // Read the space, then read the thread inside it.
        try await store.markReadLocally(spaceName: "spaces/A", at: try date("2026-07-01T14:00:00Z"))
        let threadMark = try date("2026-07-01T14:30:00Z")
        try await store.markThreadRead(threadName: "spaces/A/threads/T1", at: threadMark)

        let mark = try #require(try await store.unreadMark(spaceName: "spaces/A"))
        try await store.markUnreadLocally(spaceName: "spaces/A", at: mark)

        #expect(try thread(in: container)?.lastReadTime == threadMark)
        #expect(try thread(in: container)?.unreadReplyCount == 0)
        #expect(try space(in: container)?.unreadThreadCount == 0)
        // The reply is the newest message, so the space's own count has it now. The
        // thread total must not add it a second time.
        #expect(try space(in: container)?.unreadCount == 1)
        #expect(try await store.totalUnread() == 1)
    }

    /// A space nobody has opened has no history to sit behind, so the mark comes off
    /// its last activity instead: no count to show, but `hasUnread` gives the sidebar
    /// its dot — the same shape an unbackfilled space already has.
    @Test func aSpaceWithNoCachedHistoryFallsBackToItsLastActivity() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try threadedSpace(lastActive: "2026-07-01T13:00:00Z")])
        try await store.applyReadState(try date("2026-07-01T14:00:00Z"), for: "spaces/A")

        let mark = try #require(try await store.unreadMark(spaceName: "spaces/A"))
        #expect(mark == (try date("2026-07-01T12:59:59Z")))

        try await store.markUnreadLocally(spaceName: "spaces/A", at: mark)
        let space = try space(in: container)
        #expect(space?.unreadCount == 0)
        #expect(space?.hasUnread == true)
        #expect(space?.isUnread == true)
    }

    /// Nothing has ever happened here, so there is nothing to be unread about — and
    /// the caller is told so rather than sending Chat a mark it cannot act on.
    @Test func aSpaceWithNoActivityHasNothingToMarkUnread() async throws {
        let (store, _) = try makeStore()
        try await store.upsertSpaces([try threadedSpace()])

        #expect(try await store.unreadMark(spaceName: "spaces/A") == nil)
        #expect(try await store.unreadMark(spaceName: "spaces/missing") == nil)
    }

    /// A message still in flight is not something to come back and read, and it is not
    /// on the server for Chat to measure the mark against either.
    @Test func anInFlightMessageIsNotWhatTheMarkSitsBehind() async throws {
        let (store, _) = try await readSpace()
        try await store.insertPendingMessage(
            clientID: "client-1",
            text: "mine",
            spaceName: "spaces/A",
            senderName: "users/me",
            senderDisplayName: "Me",
            threadName: nil
        )

        let mark = try await store.unreadMark(spaceName: "spaces/A")

        #expect(mark == (try date("2026-07-01T12:59:59Z")))
    }
}
