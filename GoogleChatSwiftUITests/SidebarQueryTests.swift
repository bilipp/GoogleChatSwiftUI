import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// The sidebar's filters exist twice over — once as SwiftData predicates that narrow the
/// fetch, once as the in-memory pass in `SidebarIndex` that decides what is drawn — and
/// these tests are what keeps the two saying the same thing.
///
/// Two different obligations, and they are not the same strength:
///
/// - ``SpaceQueries/sidebarRows(scope:kind:hasSearchQuery:now:)`` must never drop a row the
///   in-memory pass would have kept. It is allowed to return more. A predicate that is too
///   generous costs a little speed; one that is too strict makes a conversation
///   *disappear from the sidebar*, silently, for whichever filter combination it got wrong.
/// - ``SidebarCounts`` must be exact, because those numbers are shown to the user and the
///   point of them is to say what picking an option would do.
@MainActor
struct SidebarQueryTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// One space per interesting shape, so every branch of every predicate is exercised:
    /// each space type, activity inside and outside the recency window and none at all,
    /// each way of being unread, and pinned and muted in every combination that matters.
    @discardableResult
    private func seed(_ context: ModelContext, now: Date) -> [CachedSpace] {
        let recent = now.addingTimeInterval(-60 * 60)
        let old = now.addingTimeInterval(-SpaceScope.recentWindow - 60 * 60 * 24)

        var made: [CachedSpace] = []

        func add(
            _ name: String,
            type: ChatSpace.SpaceType?,
            active: Date?,
            unread: Int = 0,
            unreadThreads: Int = 0,
            didFetchReadState: Bool = false,
            lastRead: Date? = nil,
            pinned: Bool = false,
            muted: Bool = false
        ) {
            let space = CachedSpace(name: name)
            space.spaceTypeRaw = type?.rawValue
            space.lastActiveTime = active
            space.unreadCount = unread
            space.unreadThreadCount = unreadThreads
            space.didFetchReadState = didFetchReadState
            space.lastReadTime = lastRead
            space.isPinned = pinned
            space.isMuted = muted
            context.insert(space)
            made.append(space)
        }

        // Plain rows, one per type, inside and outside the window.
        add("spaces/recentRoom", type: .space, active: recent)
        add("spaces/oldRoom", type: .space, active: old)
        add("spaces/recentDM", type: .directMessage, active: recent)
        add("spaces/oldDM", type: .directMessage, active: old)
        add("spaces/recentGroup", type: .groupChat, active: recent)
        add("spaces/neverActive", type: .space, active: nil)
        // A type this build does not name, and none at all: both still count as
        // "everything" for the kind filter.
        add("spaces/unspecified", type: .unspecified, active: recent)
        add("spaces/typeless", type: nil, active: recent)

        // The three ways of being unread.
        add("spaces/unreadByCount", type: .space, active: recent, unread: 3)
        add("spaces/unreadByThreads", type: .space, active: recent, unreadThreads: 2)
        add(
            "spaces/unreadByTimestamp",
            type: .directMessage,
            active: recent,
            didFetchReadState: true,
            lastRead: recent.addingTimeInterval(-60)
        )
        // Read: the mark is newer than the activity. The timestamp half must not claim it.
        add(
            "spaces/read",
            type: .space,
            active: recent,
            didFetchReadState: true,
            lastRead: now
        )
        // Read state fetched but the endpoint gave no mark, which is not unread.
        add("spaces/noMark", type: .space, active: recent, didFetchReadState: true)
        // Unread by timestamp but long dormant, so only the unread scope should reach it.
        add(
            "spaces/oldUnread",
            type: .space,
            active: old,
            didFetchReadState: true,
            lastRead: old.addingTimeInterval(-60)
        )

        // Pinned and muted, in the combinations the rules single out.
        add("spaces/pinnedOld", type: .space, active: old, pinned: true)
        add("spaces/pinnedMutedOld", type: .space, active: old, pinned: true, muted: true)
        add("spaces/mutedRecent", type: .space, active: recent, muted: true)
        add("spaces/mutedRecentDM", type: .directMessage, active: recent, muted: true)
        add("spaces/mutedUnread", type: .space, active: recent, unread: 1, muted: true)

        try? context.save()
        return made
    }

    /// What `SidebarIndex` keeps, restated here so the predicates have something
    /// independent to be checked against.
    private func drawn(
        from spaces: [CachedSpace],
        scope: SpaceScope,
        kind: SpaceKind,
        showsMuted: Bool,
        hasQuery: Bool,
        now: Date
    ) -> Set<String> {
        var kept: Set<String> = []
        for space in spaces {
            guard kind.matches(space) else { continue }
            if hasQuery {
                // Search overrides the scope; the text itself is matched in memory.
                kept.insert(space.name)
            } else if space.isPinned {
                kept.insert(space.name)
            } else if showsMuted || !space.isMuted, scope.matches(space, now: now) {
                kept.insert(space.name)
            }
        }
        return kept
    }

    @Test func theRowQueryNeverDropsARowTheSidebarWouldDraw() throws {
        let context = try makeContext()
        let now = Date()
        let seeded = seed(context, now: now)

        for scope in SpaceScope.allCases {
            for kind in SpaceKind.allCases {
                for hasQuery in [false, true] {
                    for showsMuted in [false, true] {
                        var descriptor = FetchDescriptor<CachedSpace>()
                        descriptor.predicate = SpaceQueries.sidebarRows(
                            scope: scope,
                            kind: kind,
                            hasSearchQuery: hasQuery,
                            now: now
                        )
                        let fetched = Set(try context.fetch(descriptor).map(\.name))
                        let needed = drawn(
                            from: seeded,
                            scope: scope,
                            kind: kind,
                            showsMuted: showsMuted,
                            hasQuery: hasQuery,
                            now: now
                        )
                        let dropped = needed.subtracting(fetched)
                        #expect(
                            dropped.isEmpty,
                            """
                            \(scope.rawValue)/\(kind.rawValue) \
                            (query: \(hasQuery), muted: \(showsMuted)) \
                            dropped \(dropped.sorted())
                            """
                        )
                    }
                }
            }
        }
    }

    @Test func theCountsMatchWhatPickingTheOptionWouldList() throws {
        let context = try makeContext()
        let now = Date()
        let seeded = seed(context, now: now)

        for scope in SpaceScope.allCases {
            for kind in SpaceKind.allCases {
                for mutedOnly in [false, true] {
                    let expected = seeded.filter { space in
                        kind.matches(space)
                            && scope.matches(space, now: now)
                            && (!mutedOnly || (space.isMuted && !space.isPinned))
                    }.count
                    let counted = try SidebarCounts.count(
                        scope: scope,
                        kind: kind,
                        mutedOnly: mutedOnly,
                        now: now,
                        in: context
                    )
                    #expect(
                        counted == expected,
                        """
                        \(scope.rawValue)/\(kind.rawValue) (mutedOnly: \(mutedOnly)) \
                        counted \(counted), expected \(expected)
                        """
                    )
                }
            }
        }
    }

    /// The narrowing has to actually narrow, or the fetch it replaced was cheaper.
    @Test func theDefaultScopeAsksForFewerRowsThanTheCacheHolds() throws {
        let context = try makeContext()
        let now = Date()
        seed(context, now: now)

        var descriptor = FetchDescriptor<CachedSpace>()
        descriptor.predicate = SpaceQueries.sidebarRows(
            scope: .recent,
            kind: .all,
            hasSearchQuery: false,
            now: now
        )
        let narrowed = try context.fetchCount(descriptor)
        let everything = try context.fetchCount(FetchDescriptor<CachedSpace>())

        #expect(narrowed < everything)
        // Dormant rows are the ones it should be leaving behind, pins excepted.
        #expect(!(try context.fetch(descriptor).contains { $0.name == "spaces/oldRoom" }))
        #expect(try context.fetch(descriptor).contains { $0.name == "spaces/pinnedOld" })
    }

    /// Search reaches conversations the scope would hide, so the fetch has to stop
    /// narrowing the moment there is a query — the case that would otherwise make a
    /// dormant DM unfindable by name.
    @Test func searchWidensTheFetchBeyondTheScope() throws {
        let context = try makeContext()
        let now = Date()
        seed(context, now: now)

        var descriptor = FetchDescriptor<CachedSpace>()
        descriptor.predicate = SpaceQueries.sidebarRows(
            scope: .recent,
            kind: .all,
            hasSearchQuery: true,
            now: now
        )
        let names = Set(try context.fetch(descriptor).map(\.name))
        #expect(names.contains("spaces/oldDM"))
        #expect(names.contains("spaces/oldRoom"))
    }

    /// The cutoff is quantized so the descriptor does not change between body
    /// evaluations — an ever-moving one would refetch every pass, which is the cost the
    /// narrowing exists to avoid.
    @Test func theRecencyCutoffIsStableWithinTheHour() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff = SpaceQueries.recentCutoff(base)
        for offset in [1.0, 60.0, 600.0, 1800.0] {
            #expect(SpaceQueries.recentCutoff(base.addingTimeInterval(offset)) == cutoff)
        }
        // And it never looks forward, so it cannot exclude a row the exact rule keeps.
        #expect(cutoff <= base.addingTimeInterval(-SpaceScope.recentWindow))
    }
}
