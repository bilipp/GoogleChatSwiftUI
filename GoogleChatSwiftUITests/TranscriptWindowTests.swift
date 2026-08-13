import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// The window is what stops a long conversation getting slower the more of it you read.
/// Its whole job is to answer one question at the top of the transcript — is there more
/// on disk, or is it time to ask Chat — and to be wrong only in the direction that costs
/// a fetch rather than the direction that loses history.
struct TranscriptWindowTests {
    /// A conversation with more cached than the window shows widens locally. This is the
    /// case the rework exists for: the reader has already paid for this history once.
    @Test func historyBelowTheWindowIsNotFetchedAgain() {
        let window = TranscriptWindow()
        #expect(!window.coversEverythingCached(2000))
    }

    /// The window has reached the oldest message on disk, so the only place left to look
    /// is the server.
    @Test func aWindowPastTheCacheIsExhausted() {
        let window = TranscriptWindow()
        #expect(window.coversEverythingCached(40))
    }

    /// The boundary that a row count alone cannot see, and the reason the store is
    /// counted instead: a window ending exactly at the oldest cached message comes back
    /// full, looking identical to one with history beneath it.
    @Test func aWindowEndingExactlyAtTheCacheIsExhausted() {
        let window = TranscriptWindow()
        #expect(window.coversEverythingCached(TranscriptWindow.initialLimit))
    }

    /// Widening is what shows cached history, so it has to keep making progress. Every
    /// trip to the top widens, including the ones that also go to the server — otherwise
    /// a space whose cache ends at the window's edge would ask forever and draw nothing.
    @Test func wideningAlwaysAdvances() {
        var window = TranscriptWindow()
        let cached = window.limit + 1
        #expect(!window.coversEverythingCached(cached))
        window.widen()
        #expect(window.coversEverythingCached(cached))
    }

    /// A search hit or a followed link lands deep in a conversation. The window has to
    /// open past it before there is a row to scroll to at all.
    @Test func reachingForAnOlderMessageOpensPastIt() {
        var window = TranscriptWindow()
        window.reach(pastNewerMessages: 900)
        #expect(window.limit > 900)
    }

    /// And it lands with room above, so arriving somewhere does not immediately read as
    /// a request for more history.
    @Test func aReachedMessageHasHistoryAboveIt() {
        var window = TranscriptWindow()
        window.reach(pastNewerMessages: 900)
        #expect(window.limit - 900 >= TranscriptWindow.step)
    }

    /// Jumping backwards must never take away history already paged in — the reader
    /// scrolled for it, and a jump is not a reason to make them scroll again.
    @Test func reachingForARecentMessageNeverNarrows() {
        var window = TranscriptWindow()
        window.widen()
        window.widen()
        let opened = window.limit
        window.reach(pastNewerMessages: 3)
        #expect(window.limit == opened)
    }

    /// A conversation opens on more than one backfilled page, so a space fetched moments
    /// ago shows everything that fetch brought back rather than hiding part of it behind
    /// a scroll.
    @Test func theOpeningWindowHoldsAFetchedPage() {
        #expect(TranscriptWindow.initialLimit >= SyncEngine.historyPageSize)
    }
}

/// The fetches themselves, against a real store.
///
/// A predicate SwiftData cannot translate compiles perfectly well and then throws — or
/// answers nothing — at runtime, which for these three would mean a transcript that draws
/// the wrong end of a conversation, never pages, or refuses to reach a search hit. None of
/// that is visible in the source, so it is checked here.
@MainActor
struct TranscriptQueryTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// One space with `count` messages a minute apart, and a second space beside it so
    /// that a query which forgets to narrow by space is caught rather than passing on a
    /// store where every row happens to belong to the one being asked about.
    private func seed(_ context: ModelContext, count: Int) throws -> CachedSpace {
        let space = CachedSpace(name: "spaces/A")
        context.insert(space)
        for index in 0..<count {
            let message = CachedMessage(name: "spaces/A/messages/\(index)")
            message.createTime = epoch.addingTimeInterval(Double(index) * 60)
            message.space = space
            context.insert(message)
        }

        let other = CachedSpace(name: "spaces/B")
        context.insert(other)
        for index in 0..<25 {
            let message = CachedMessage(name: "spaces/B/messages/\(index)")
            // Interleaved with A's, so a missing space clause shows up as a wrong count
            // rather than as a count that happens to still be right.
            message.createTime = epoch.addingTimeInterval(Double(index) * 60 + 30)
            message.space = other
            context.insert(message)
        }

        try context.save()
        return space
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// The point of the whole rework: a space with a thousand messages cached hands the
    /// transcript a window, not a thousand rows.
    @Test func theWindowDrawsOnlyItsShareOfALongConversation() throws {
        let context = try makeContext()
        try seed(context, count: 1000)

        let window = try context.fetch(TranscriptQueries.window(in: "spaces/A", limit: 150))
        #expect(window.count == 150)
    }

    /// And it is the *newest* share. Opening a conversation at message 1 of 1000 would be
    /// a stranger failure than the slowness it replaced.
    @Test func theWindowHoldsTheNewestMessages() throws {
        let context = try makeContext()
        try seed(context, count: 1000)

        let window = try context.fetch(TranscriptQueries.window(in: "spaces/A", limit: 150))
        #expect(window.first?.name == "spaces/A/messages/999")
        #expect(window.last?.name == "spaces/A/messages/850")
    }

    /// A window wider than the conversation is the whole conversation, not an error.
    @Test func aShortConversationIsDrawnWhole() throws {
        let context = try makeContext()
        try seed(context, count: 12)

        let window = try context.fetch(TranscriptQueries.window(in: "spaces/A", limit: 150))
        #expect(window.count == 12)
    }

    /// The count that decides between widening the window and going to the server. It has
    /// to be this space's messages only — the store holds every conversation.
    @Test func theCachedCountIsPerConversation() throws {
        let context = try makeContext()
        try seed(context, count: 300)

        let cached = try context.fetchCount(TranscriptQueries.allMessages(in: "spaces/A"))
        #expect(cached == 300)
        #expect(!TranscriptWindow().coversEverythingCached(cached))
    }

    /// How far the window has to open for a search hit to be in the transcript at all.
    /// The optional-timestamp comparison here is the one SwiftData is fussiest about.
    @Test func reachCountsOnlyTheMessagesAfterTheTarget() throws {
        let context = try makeContext()
        try seed(context, count: 1000)

        let target = try context.fetch(
            TranscriptQueries.message(named: "spaces/A/messages/200")
        ).first
        let created = try #require(target?.createTime)

        let newer = try context.fetchCount(
            TranscriptQueries.messages(in: "spaces/A", after: created)
        )
        #expect(newer == 799)
    }

    /// End to end: the window opened for a search hit actually contains it.
    @Test func aWindowOpenedForAHitContainsIt() throws {
        let context = try makeContext()
        try seed(context, count: 1000)

        let created = try #require(
            try context.fetch(TranscriptQueries.message(named: "spaces/A/messages/200"))
                .first?.createTime
        )
        let newer = try context.fetchCount(
            TranscriptQueries.messages(in: "spaces/A", after: created)
        )

        var window = TranscriptWindow()
        window.reach(pastNewerMessages: newer)

        let drawn = try context.fetch(
            TranscriptQueries.window(in: "spaces/A", limit: window.limit)
        )
        #expect(drawn.contains { $0.name == "spaces/A/messages/200" })
    }

    /// A message this account has never cached leaves the window where it was, rather
    /// than opening it onto the whole conversation on the strength of a count of zero.
    @Test func anUncachedTargetIsNotFoundAtAll() throws {
        let context = try makeContext()
        try seed(context, count: 40)

        let missing = try context.fetch(
            TranscriptQueries.message(named: "spaces/A/messages/nope")
        )
        #expect(missing.isEmpty)
    }
}
