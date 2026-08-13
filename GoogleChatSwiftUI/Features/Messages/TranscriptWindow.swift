import Foundation
import SwiftData

/// How much of a conversation's cached history the transcript actually draws.
///
/// The transcript used to ask for all of it. `@Query` refetches on every write to the
/// store, and opening a conversation writes several times over — history merge, sender
/// resolution, read mark, thread state — so a space with two thousand cached messages
/// materialized two thousand rows, rebuilt a dictionary over them, re-bucketed them by
/// day and handed `ForEach` two thousand identities to diff, repeatedly, before the
/// reader had done anything at all. Worse, it got slower the more of the conversation
/// they had read: paging back added to a set that nothing ever took anything out of.
///
/// So the transcript draws a window over the newest messages, and the window opens
/// backwards as the reader scrolls. Reaching the top of it now means one of two things,
/// and the difference is the point of this type. History that is already cached is shown
/// by widening the window — a re-fetch of a few hundred rows, no round trip, no waiting.
/// Only once the window has reached the oldest message on disk does reaching the top mean
/// asking Chat for more.
///
/// `nonisolated` so the tests can exercise the arithmetic without a view around it.
nonisolated struct TranscriptWindow: Equatable {
    /// Rows drawn when a conversation opens. Several screenfuls, and comfortably more
    /// than ``SyncEngine/historyPageSize`` so a space backfilled a moment ago shows
    /// every message that backfill just fetched.
    static let initialLimit = 150

    /// How much further back one step reaches. Large enough that a reader scrolling
    /// steadily is not stepping once per screenful, small enough that the step itself is
    /// a fetch nobody notices.
    static let step = 150

    private(set) var limit: Int

    init(limit: Int = TranscriptWindow.initialLimit) {
        self.limit = limit
    }

    /// Whether widening would reveal anything, given how many messages the space has on
    /// disk in total.
    ///
    /// The transcript's own row count cannot answer this. A window with more history
    /// beneath it and a window that happens to end exactly at the oldest cached message
    /// both come back full, and the two need opposite treatment: one widens, the other
    /// has to go to the server. So the total comes from a count against the store.
    func coversEverythingCached(_ cachedCount: Int) -> Bool {
        limit >= cachedCount
    }

    mutating func widen() {
        limit += Self.step
    }

    /// Opens the window far enough to hold a message with `newerCount` messages after it
    /// — a search hit, or the message a link named.
    ///
    /// Never narrows, so a jump backwards into a conversation cannot take away history
    /// the reader had already paged in. Lands the target a step short of the top rather
    /// than exactly at it, so there is something above what they were sent to and the
    /// arrival does not immediately read as a request for more history.
    mutating func reach(pastNewerMessages newerCount: Int) {
        limit = max(limit, newerCount + 1 + Self.step)
    }
}

/// The three fetches a windowed transcript is built from.
///
/// Gathered here rather than written where they are used, for the reason ``SpaceQueries``
/// exists: a predicate SwiftData cannot translate does not fail to compile, it throws when
/// it runs — or worse, quietly answers nothing — so these are exercised against a real
/// store by the tests rather than trusted because they read correctly.
nonisolated enum TranscriptQueries {
    /// The newest `limit` messages in a space.
    ///
    /// Sorted newest-first because that is the only way a limit can mean "the newest",
    /// which is the end of a conversation worth opening on. The transcript re-orders for
    /// itself — see `days` — so nothing downstream depends on this direction.
    static func window(in spaceName: String, limit: Int) -> FetchDescriptor<CachedMessage> {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate<CachedMessage> { $0.space?.name == spaceName },
            sortBy: [SortDescriptor(\CachedMessage.createTime, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Every message cached for a space, for counting. See
    /// ``TranscriptWindow/coversEverythingCached(_:)`` for what the count decides.
    static func allMessages(in spaceName: String) -> FetchDescriptor<CachedMessage> {
        FetchDescriptor<CachedMessage>(
            predicate: #Predicate<CachedMessage> { $0.space?.name == spaceName }
        )
    }

    /// One message by name.
    static func message(named messageName: String) -> FetchDescriptor<CachedMessage> {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate<CachedMessage> { $0.name == messageName }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Messages in a space posted after an instant — how far the window has to open to
    /// reach the message at that instant.
    ///
    /// The optional timestamp is compared through `flatMap` rather than unwrapped:
    /// SwiftData rejects a force-unwrap inside `#Predicate` outright, and `??` on
    /// anything but an optional `Bool` is not an expression it accepts.
    static func messages(
        in spaceName: String,
        after created: Date
    ) -> FetchDescriptor<CachedMessage> {
        FetchDescriptor<CachedMessage>(
            predicate: #Predicate<CachedMessage> { message in
                message.space?.name == spaceName
                    && (message.createTime.flatMap { $0 > created } ?? false)
            }
        )
    }
}
