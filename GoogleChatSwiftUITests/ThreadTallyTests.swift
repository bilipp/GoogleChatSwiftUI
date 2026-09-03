import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// The thread tallies are maintained incrementally: everything that changes one thread
/// recomputes that thread and moves the space's totals by the difference, rather than
/// walking every thread in the room. That walk was the app's single most expensive
/// operation — in a space where every message starts its own thread it faulted one
/// thread's messages per message in the space, on every arriving message — but the
/// bookkeeping that replaces it is the classic way to get a counter wrong.
///
/// So these tests do not check the counters against a remembered number. They recompute
/// the answer from the cached messages, independently of the store, and compare after
/// every step of a long sequence. A delta that is right once and wrong on the fourth
/// operation is exactly the failure mode, and only a sequence catches it.
struct ThreadTallyTests {
    // MARK: - The oracle

    /// What the tallies should be, computed from the messages rather than from the
    /// counters — a second implementation of the rules in `ChatStore.recomputeTallies`,
    /// deliberately written out longhand here so a change to one has to be argued
    /// against the other.
    private struct Tallies: Equatable, CustomStringConvertible {
        var unreadThreadCount = 0
        var unreadThreadReplyCount = 0
        /// Per thread name, so a wrong total says which thread it came from.
        var replies: [String: Int] = [:]
        var unreadReplies: [String: Int] = [:]
        /// The two names the thread list reads instead of walking `thread.messages` —
        /// see ``CachedThread/rootMessageName``. Checked here rather than in a test of
        /// their own because they are written by the same pass that writes the tallies,
        /// so every step of the sequence below is already a case for them: a reply
        /// arriving moves the last reply, a deletion moves it back, and a root being
        /// tombstoned must leave the root where it is.
        var roots: [String: String] = [:]
        var lastReplies: [String: String] = [:]

        var description: String {
            """
            threads unread: \(unreadThreadCount), hidden replies: \(unreadThreadReplyCount)
            replies: \(replies.sorted { $0.key < $1.key })
            unread:  \(unreadReplies.sorted { $0.key < $1.key })
            roots:   \(roots.sorted { $0.key < $1.key })
            last:    \(lastReplies.sorted { $0.key < $1.key })
            """
        }
    }

    private func expected(_ spaceName: String, in container: ModelContainer) throws -> Tallies {
        let context = ModelContext(container)
        guard let space = try context.fetch(
            FetchDescriptor<CachedSpace>(predicate: #Predicate { $0.name == spaceName })
        ).first else { return Tallies() }

        let spaceMark = space.lastReadTime ?? .distantPast
        var tallies = Tallies()

        for thread in space.threads {
            let mark = thread.lastReadTime ?? .distantPast
            var replies = 0
            var unread = 0
            var hidden = 0

            for message in thread.messages {
                guard !message.isDeleted, message.isThreadReply else { continue }
                replies += 1
                let created = message.createTime ?? .distantPast
                guard thread.didSeedReadState, created > mark else { continue }
                unread += 1
                if created <= spaceMark { hidden += 1 }
            }

            tallies.replies[thread.name] = replies
            tallies.unreadReplies[thread.name] = unread
            if unread > 0 { tallies.unreadThreadCount += 1 }
            tallies.unreadThreadReplyCount += hidden

            // The opening message: the earliest non-reply, or failing that the earliest
            // message of any kind. Deleted messages count — a thread whose root was
            // tombstoned still has that root, and shows "Message deleted" as its snippet.
            let byAge = thread.messages.sorted {
                ($0.createTime ?? .distantPast) < ($1.createTime ?? .distantPast)
            }
            if let root = byAge.first(where: { !$0.isThreadReply }) ?? byAge.first {
                tallies.roots[thread.name] = root.name
            }
            // The newest reply still standing, which is the one the list names a sender
            // from. A deletion moves this back to the reply before it.
            if let newest = byAge.last(where: { $0.isThreadReply && !$0.isDeleted }) {
                tallies.lastReplies[thread.name] = newest.name
            }
        }
        return tallies
    }

    /// What the store actually recorded.
    private func recorded(_ spaceName: String, in container: ModelContainer) throws -> Tallies {
        let context = ModelContext(container)
        guard let space = try context.fetch(
            FetchDescriptor<CachedSpace>(predicate: #Predicate { $0.name == spaceName })
        ).first else { return Tallies() }

        var tallies = Tallies(
            unreadThreadCount: space.unreadThreadCount,
            unreadThreadReplyCount: space.unreadThreadReplyCount
        )
        for thread in space.threads {
            tallies.replies[thread.name] = thread.replyCount
            tallies.unreadReplies[thread.name] = thread.unreadReplyCount
            tallies.roots[thread.name] = thread.rootMessageName
            tallies.lastReplies[thread.name] = thread.lastReplyMessageName
        }
        return tallies
    }

    /// Fails naming the step, since the point of a sequence is knowing which operation
    /// broke it.
    private func check(
        _ step: String,
        _ spaceName: String = "spaces/A",
        in container: ModelContainer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let want = try expected(spaceName, in: container)
        let got = try recorded(spaceName, in: container)
        #expect(got == want, "after \(step)\n\ngot:\n\(got)\n\nwant:\n\(want)", sourceLocation: sourceLocation)
    }

    // MARK: - Fixtures

    private func makeStore() throws -> (ChatStore, ModelContainer) {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (ChatStore(modelContainer: container), container)
    }

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
        in space: String = "spaces/A"
    ) throws -> ChatMessage {
        let json = """
        {
          "name":"\(space)/messages/\(id)",
          "text":"\(id)",
          "createTime":"\(timestamp)",
          "sender":{"name":"users/other"},
          "thread":{"name":"\(space)/threads/\(thread)"},
          "threadReply":\(isReply)
        }
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func date(_ iso: String) throws -> Date {
        try Date(iso, strategy: .iso8601)
    }

    // MARK: - The sequence

    /// Every operation that touches the tallies, one after another, against the oracle
    /// after each. This is the test the incremental bookkeeping exists to pass.
    @Test func incrementalUpdatesAgreeWithAFullRecountAtEveryStep() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([threadedSpace()])

        // Three thread roots, arriving in separate merges — each merge takes the
        // incremental path over only the thread it touched.
        for (index, id) in ["T1", "T2", "T3"].enumerated() {
            try await store.mergeMessages(
                [try message("root\(id)", thread: id, at: "2026-07-01T1\(index):00:00Z", isReply: false)],
                into: "spaces/A"
            )
            try check("root of \(id) arriving", in: container)
        }

        // Read state lands, which seeds every thread's mark and is one of the few
        // operations that has to recount the whole space.
        try await store.applyReadState(try date("2026-07-01T12:00:00Z"), for: "spaces/A")
        try check("read state landing", in: container)

        // Replies arriving one at a time, some before the space's mark and some after —
        // the two sides of the hidden/visible split the space totals depend on.
        let replies = [
            ("r1", "T1", "2026-07-01T11:30:00Z"),
            ("r2", "T1", "2026-07-01T13:00:00Z"),
            ("r3", "T2", "2026-07-01T14:00:00Z"),
            ("r4", "T2", "2026-07-01T14:30:00Z"),
            ("r5", "T3", "2026-07-01T11:45:00Z"),
        ]
        for (id, thread, timestamp) in replies {
            try await store.mergeMessages(
                [try message(id, thread: thread, at: timestamp, isReply: true)],
                into: "spaces/A"
            )
            try check("reply \(id) arriving in \(thread)", in: container)
        }

        // Several replies in one merge, across two threads — the batch path.
        try await store.mergeMessages(
            [
                try message("r6", thread: "T1", at: "2026-07-01T15:00:00Z", isReply: true),
                try message("r7", thread: "T3", at: "2026-07-01T15:30:00Z", isReply: true),
            ],
            into: "spaces/A"
        )
        try check("a merge spanning two threads", in: container)

        // One thread opened.
        try await store.markThreadRead(threadName: "spaces/A/threads/T1", at: try date("2026-07-01T16:00:00Z"))
        try check("opening T1", in: container)

        // The server's own marks, arriving for two threads at once.
        try await store.applyThreadReadStates([
            ThreadReadState(threadName: "spaces/A/threads/T2", lastReadTime: try date("2026-07-01T14:15:00Z")),
            ThreadReadState(threadName: "spaces/A/threads/T3", lastReadTime: nil),
        ])
        try check("server thread read states", in: container)

        // A reply deleted out from under a tally.
        try await store.applyDeletion(to: "spaces/A/messages/r4")
        try check("deleting reply r4", in: container)

        // A whole thread taken down, replies and all.
        try await store.applyDeletion(to: "spaces/A/messages/rootT3", includingThreadReplies: true)
        try check("deleting T3's root and its replies", in: container)

        // The space's own mark moving, which invalidates every thread's hidden count at
        // once and must therefore recount rather than adjust.
        try await store.markReadLocally(spaceName: "spaces/A", at: try date("2026-07-01T17:00:00Z"))
        try check("marking the space read", in: container)

        // Now the interesting half, and the one a shorter sequence misses entirely. A
        // reply is "hidden" only when it is newer than its *thread's* mark and no newer
        // than the *space's* — which needs the space to have been read after the thread
        // was, the state the two steps above have just produced. Every incremental
        // operation from here on is adjusting a non-zero contribution rather than a zero
        // one, which is the only way the `- wasHidden` term is load-bearing.
        for (id, timestamp) in [("r8", "16:30"), ("r9", "16:45")] {
            try await store.mergeMessages(
                [try message(id, thread: "T1", at: "2026-07-01T\(timestamp):00Z", isReply: true)],
                into: "spaces/A"
            )
            try check("hidden reply \(id) arriving after the space was read", in: container)
        }

        // A second thread's worth, so the space total is a sum of two contributions
        // rather than one.
        try await store.mergeMessages(
            [try message("r10", thread: "T2", at: "2026-07-01T16:50:00Z", isReply: true)],
            into: "spaces/A"
        )
        try check("a hidden reply in a second thread", in: container)

        // Deleting one of them takes its contribution back out.
        try await store.applyDeletion(to: "spaces/A/messages/r8")
        try check("deleting a hidden reply", in: container)

        // And opening the thread clears the rest of its share in one go.
        try await store.markThreadRead(threadName: "spaces/A/threads/T1", at: try date("2026-07-01T17:30:00Z"))
        try check("opening a thread that held hidden replies", in: container)

        try await store.markUnreadLocally(spaceName: "spaces/A", at: try date("2026-07-01T13:30:00Z"))
        try check("marking the space unread", in: container)

        try await store.markAllThreadsRead(spaceName: "spaces/A", at: try date("2026-07-01T18:00:00Z"))
        try check("marking every thread read", in: container)

        // And having ended up read, it really is read — a sequence that agrees with the
        // oracle at every step but drifts to nonsense in both would still pass above.
        let space = try #require(
            try ModelContext(container).fetch(
                FetchDescriptor<CachedSpace>(predicate: #Predicate { $0.name == "spaces/A" })
            ).first
        )
        #expect(space.unreadThreadCount == 0)
        #expect(space.unreadThreadReplyCount == 0)
    }

    /// A store written before the tallies were kept incrementally has totals that no
    /// per-thread contribution adds up to, so the first incremental update has nothing
    /// sound to adjust. The version stamp is what catches that: an unstamped space is
    /// recounted in full and stamped, and only then trusted.
    @Test func aSpaceComputedByOlderRulesIsRecountedRatherThanAdjusted() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([threadedSpace()])
        try await store.mergeMessages(
            [
                try message("root", thread: "T1", at: "2026-07-01T11:00:00Z", isReply: false),
                try message("r1", thread: "T1", at: "2026-07-01T13:00:00Z", isReply: true),
                try message("r2", thread: "T2", at: "2026-07-01T13:30:00Z", isReply: true),
            ],
            into: "spaces/A"
        )
        try await store.applyReadState(try date("2026-07-01T12:00:00Z"), for: "spaces/A")

        // The state an older build left behind: totals present, the per-thread
        // contributions they were built from absent, and no version stamp.
        let context = ModelContext(container)
        let space = try #require(
            try context.fetch(
                FetchDescriptor<CachedSpace>(predicate: #Predicate { $0.name == "spaces/A" })
            ).first
        )
        space.threadTallyVersion = 0
        space.unreadThreadReplyCount = 99
        space.unreadThreadCount = 99
        for thread in space.threads { thread.hiddenUnreadReplyCount = 0 }
        try context.save()

        // Any operation that would normally adjust by difference.
        try await store.markThreadRead(threadName: "spaces/A/threads/T1", at: try date("2026-07-01T16:00:00Z"))

        try check("the first touch of an unstamped space", in: container)
        #expect(try recorded("spaces/A", in: container).unreadThreadCount == 1)
        let stamped = try #require(
            try ModelContext(container).fetch(
                FetchDescriptor<CachedSpace>(predicate: #Predicate { $0.name == "spaces/A" })
            ).first
        )
        #expect(stamped.threadTallyVersion == ChatStore.threadTallyVersion)
    }

    /// The bound on the transcript's thread query is not a guess — see
    /// ``TranscriptQueries/threads(in:limit:)``. A thread holding a message in the
    /// window cannot sort outside the newest `limit` threads by activity, because a
    /// thread's activity is the newest of its messages and only `limit` messages are
    /// that recent.
    @Test func theBoundedThreadQueryCoversEveryThreadInTheWindow() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([threadedSpace()])

        // The shape that made this expensive: one thread per message, forty of them.
        var messages: [ChatMessage] = []
        for index in 0..<40 {
            let minute = String(format: "%02d", index)
            messages.append(
                try message("m\(index)", thread: "T\(index)", at: "2026-07-01T10:\(minute):00Z", isReply: false)
            )
        }
        try await store.mergeMessages(messages, into: "spaces/A")

        let limit = 10
        let context = ModelContext(container)
        let window = try context.fetch(TranscriptQueries.window(in: "spaces/A", limit: limit))
        let threads = try context.fetch(TranscriptQueries.threads(in: "spaces/A", limit: limit))

        #expect(window.count == limit)
        #expect(threads.count == limit)

        // Every thread the window's messages belong to is in the bounded fetch.
        let reachable = Set(threads.map(\.name))
        for message in window {
            let name = try #require(message.threadName)
            #expect(reachable.contains(name), "\(name) is in the window but not in the bounded thread fetch")
        }
    }
}
