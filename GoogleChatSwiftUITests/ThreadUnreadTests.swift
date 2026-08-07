import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// Thread read marks are this app's own state — Chat has no way to store them, since
/// `getThreadReadState` has no update counterpart — so nothing but these tests can
/// catch a rule that has drifted.
///
/// The bug they exist for: a reply in a threaded space never appears in the main
/// transcript, and opening the space marks the whole space read. Together those made
/// an unread reply both unbadged and invisible, with no route to it at all.
struct ThreadUnreadTests {
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
    private func threadedSpace(_ id: String = "A") throws -> ChatSpace {
        let json = """
        {"name":"spaces/\(id)","spaceType":"SPACE","spaceThreadingState":"THREADED_MESSAGES"}
        """
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    private func message(
        _ id: String,
        thread: String,
        at timestamp: String,
        isReply: Bool,
        sender: String = "users/other",
        in space: String = "spaces/A"
    ) throws -> ChatMessage {
        let json = """
        {
          "name":"\(space)/messages/\(id)",
          "text":"\(id)",
          "createTime":"\(timestamp)",
          "sender":{"name":"\(sender)"},
          "thread":{"name":"\(space)/threads/\(thread)"},
          "threadReply":\(isReply)
        }
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func thread(_ name: String, in container: ModelContainer) throws -> CachedThread? {
        let context = ModelContext(container)
        return try context.fetch(
            FetchDescriptor<CachedThread>(predicate: #Predicate { $0.name == name })
        ).first
    }

    private func space(_ name: String, in container: ModelContainer) throws -> CachedSpace? {
        let context = ModelContext(container)
        return try context.fetch(
            FetchDescriptor<CachedSpace>(predicate: #Predicate { $0.name == name })
        ).first
    }

    /// A space read at noon, with a reply that landed after it.
    ///
    /// Messages first, then read state — the order the app itself works in, and the
    /// order that lets `unreadCount` see the reply. Timestamps are safely in the past
    /// so that marking something read *now* moves its mark forward rather than back.
    private func storeWithOneUnreadReply() async throws -> (ChatStore, ModelContainer) {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([threadedSpace()])
        try await store.mergeMessages(
            [
                try message("root", thread: "T1", at: "2026-07-01T11:00:00Z", isReply: false),
                try message("r1", thread: "T1", at: "2026-07-01T13:00:00Z", isReply: true),
            ],
            into: "spaces/A"
        )
        try await store.applyReadState(readMark, for: "spaces/A")
        return (store, container)
    }

    private var readMark: Date {
        try! Date("2026-07-01T12:00:00Z", strategy: .iso8601)
    }

    @Test func aReplyAfterTheReadMarkIsUnread() async throws {
        let (_, container) = try await storeWithOneUnreadReply()

        let thread = try thread("spaces/A/threads/T1", in: container)
        #expect(thread?.unreadReplyCount == 1)
        #expect(thread?.replyCount == 1)
        #expect(try space("spaces/A", in: container)?.unreadThreadCount == 1)
    }

    /// The whole point. Opening the space clears its badge, and used to clear the
    /// thread with it — leaving a reply that was unread, unreachable, and unmarked.
    @Test func openingTheSpaceDoesNotClearUnreadThreads() async throws {
        let (store, container) = try await storeWithOneUnreadReply()

        try await store.markReadLocally(spaceName: "spaces/A", at: Date())

        let space = try space("spaces/A", in: container)
        #expect(space?.unreadCount == 0)
        #expect(space?.unreadThreadCount == 1)
        #expect(try thread("spaces/A/threads/T1", in: container)?.unreadReplyCount == 1)
    }

    @Test func openingTheThreadClearsIt() async throws {
        let (store, container) = try await storeWithOneUnreadReply()

        let previous = try await store.markThreadRead(threadName: "spaces/A/threads/T1")

        // The mark it replaced comes back so the pane can still draw the line the
        // user came to find.
        #expect(previous == readMark)
        #expect(try thread("spaces/A/threads/T1", in: container)?.unreadReplyCount == 0)
        #expect(try space("spaces/A", in: container)?.unreadThreadCount == 0)
    }

    /// History cached before read state arrives has nothing to measure against. If it
    /// counted as unread on sight, every thread in the cache would light up on first
    /// launch — so it stays silent until the space's read mark lands.
    @Test func threadsCachedBeforeReadStateAreSeededRatherThanCountedUnread() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([threadedSpace()])
        try await store.mergeMessages(
            [
                try message("root", thread: "T1", at: "2026-07-01T11:00:00Z", isReply: false),
                try message("r1", thread: "T1", at: "2026-07-01T11:30:00Z", isReply: true),
            ],
            into: "spaces/A"
        )

        #expect(try thread("spaces/A/threads/T1", in: container)?.didSeedReadState == false)
        #expect(try thread("spaces/A/threads/T1", in: container)?.unreadReplyCount == 0)

        // The read mark postdates the reply, so it was already read on the web.
        try await store.applyReadState(readMark, for: "spaces/A")

        #expect(try thread("spaces/A/threads/T1", in: container)?.didSeedReadState == true)
        #expect(try thread("spaces/A/threads/T1", in: container)?.unreadReplyCount == 0)
    }

    /// Chat reports a thread nobody explicitly opened as read at the epoch. Letting
    /// that overwrite a mark seeded from the space would resurrect the whole cache.
    @Test func serverThreadReadStateOnlyEverMovesTheMarkForward() async throws {
        let (store, container) = try await storeWithOneUnreadReply()
        let name = "spaces/A/threads/T1"

        try await store.applyThreadReadState(.distantPast, for: name)
        #expect(try thread(name, in: container)?.lastReadTime == readMark)
        #expect(try thread(name, in: container)?.unreadReplyCount == 1)
        // Checked, so the call is not paid again on the next visit.
        #expect(try thread(name, in: container)?.didCheckServerReadState == true)

        // Read on chat.google.com after the reply landed: that one does move it.
        let later = try Date("2026-07-01T14:00:00Z", strategy: .iso8601)
        try await store.applyThreadReadState(later, for: name)
        #expect(try thread(name, in: container)?.unreadReplyCount == 0)
    }

    /// Replying is reading. Without this your own reply comes straight back at you as
    /// something unread.
    @Test func yourOwnReplyIsNotUnread() async throws {
        let (store, container) = try await storeWithOneUnreadReply()
        try await store.markThreadRead(threadName: "spaces/A/threads/T1")

        try await store.insertPendingMessage(
            clientID: "client-1",
            text: "mine",
            spaceName: "spaces/A",
            senderName: "users/me",
            senderDisplayName: "Me",
            threadName: "spaces/A/threads/T1"
        )

        #expect(try thread("spaces/A/threads/T1", in: container)?.unreadReplyCount == 0)
    }

    /// The badge counts each unread reply once. Before the space is opened its own
    /// count already covers replies newer than the read mark; after, they are the only
    /// unread left and nothing else counts them.
    @Test func theBadgeCountsAnUnreadReplyExactlyOnce() async throws {
        let (store, _) = try await storeWithOneUnreadReply()

        // Before opening: the reply is newer than the space mark, so `unreadCount`
        // has it and the thread total must not add it again.
        #expect(try await store.totalUnread() == 1)

        try await store.markReadLocally(spaceName: "spaces/A", at: Date())
        #expect(try await store.totalUnread() == 1)

        try await store.markThreadRead(threadName: "spaces/A/threads/T1")
        #expect(try await store.totalUnread() == 0)
    }

    /// "Mark all as read" means all of it — the space mark cannot reach threads, so
    /// they are cleared alongside it.
    @Test func markingAllThreadsReadClearsTheSpace() async throws {
        let (store, container) = try await storeWithOneUnreadReply()

        #expect(try await store.spacesWithUnreadThreads() == ["spaces/A"])
        try await store.markAllThreadsRead(spaceName: "spaces/A")

        #expect(try space("spaces/A", in: container)?.unreadThreadCount == 0)
        #expect(try await store.spacesWithUnreadThreads().isEmpty)
    }

    /// Grouped and unthreaded spaces render replies inline, so a thread index over
    /// them would double every message the transcript already shows.
    @Test func unthreadedSpacesGetNoThreadRows() async throws {
        let (store, container) = try makeStore()
        let flat = try GoogleTransport.decoder.decode(
            ChatSpace.self,
            from: Data(#"{"name":"spaces/B","spaceType":"SPACE"}"#.utf8)
        )
        try await store.upsertSpaces([flat])
        try await store.mergeMessages(
            [try message("m1", thread: "T1", at: "2026-07-01T13:00:00Z", isReply: true, in: "spaces/B")],
            into: "spaces/B"
        )

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<CachedThread>()).isEmpty)
    }

    /// Messages cached before threads were tracked carry no thread link, so the index
    /// has to be built over them once — otherwise reply counts read low forever.
    @Test func backfillBuildsThreadRowsOverAlreadyCachedMessages() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([threadedSpace()])
        try await store.mergeMessages(
            [
                try message("root", thread: "T1", at: "2026-07-01T11:00:00Z", isReply: false),
                try message("r1", thread: "T1", at: "2026-07-01T13:00:00Z", isReply: true),
            ],
            into: "spaces/A"
        )

        // Sever the links the merge made, which is the state an older cache is in.
        let context = ModelContext(container)
        for message in try context.fetch(FetchDescriptor<CachedMessage>()) {
            message.thread = nil
        }
        for thread in try context.fetch(FetchDescriptor<CachedThread>()) {
            context.delete(thread)
        }
        try context.save()

        #expect(try await store.backfillThreads() == 2)
        #expect(try thread("spaces/A/threads/T1", in: container)?.replyCount == 1)
    }
}
