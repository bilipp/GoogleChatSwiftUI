import Foundation
import SwiftData

/// The sidebar's filters, expressed as SwiftData predicates so SQLite does the narrowing.
///
/// The sidebar used to fetch every cached space and filter in memory. That is fine at a few
/// dozen rows and not at 769: materializing one `CachedSpace` costs around 67µs, so a full
/// fetch is ~52ms of main-thread work — and `@Query` refetches on *every* write to the
/// store. Opening a conversation writes several times over (history merge, sender
/// resolution, read mark, member lookup), so the transcript arrived behind a run of 50ms
/// stalls, which is what made typing straight after a switch feel laggy. Narrowed to the
/// default Recent scope the same fetch returns ~100 rows in ~8ms.
///
/// ``sidebarRows(scope:kind:hasSearchQuery:now:)`` deliberately describes a *superset* of
/// what the sidebar draws: ``SidebarIndex`` still applies the exact rules in memory, over
/// the far smaller set this returns. A predicate that is slightly too generous costs a
/// little speed and can never hide a row, which is the only direction worth being wrong in
/// here. The counts in the filter bar's menu are held to a stricter standard, since they
/// are numbers shown to the user — see ``SidebarCounts``.
///
/// ## Two things here are load-bearing and look like style
///
/// **Each `#Predicate` is built by a function returning a non-optional `Predicate`, and
/// carries as few clauses as it can.** The unread scope has to compare two optional `Date`
/// columns, which forces a nested `flatMap` — SwiftData rejects a force-unwrap in a
/// predicate outright, and `??` on anything but an optional `Bool` is not an expression it
/// accepts. That nesting type-checks *alone* and not in company: one extra clause beside
/// it and the solver gives up, the same budget this codebase runs into elsewhere. Hence
/// ``unreadByTimestamp()`` standing by itself, ``unreadByCounters(kind:mutedOnly:)``
/// carrying the clauses it cannot, and the two together being the unread set.
///
/// **A nil kind list drops the clause rather than widening it.** SQL's `IN` never matches
/// NULL, so listing every raw value plus `nil` for "everything" silently excluded spaces
/// whose `spaceType` the API omitted. Each builder therefore has a with-kind and an
/// any-kind form, which is the duplication below.
///
/// `nonisolated` so the tests can check these against the in-memory filters they mirror.
nonisolated enum SpaceQueries {
    /// Rows the sidebar might draw, or nil where nothing narrows and every row is wanted.
    ///
    /// - Parameter hasSearchQuery: whether the sidebar's name filter is in use. Search
    ///   deliberately overrides the scope — see ``SidebarIndex`` — so it widens this to
    ///   every row. Only the empty/non-empty distinction is used rather than the text
    ///   itself, which is what keeps typing in the field from refetching per keystroke.
    static func sidebarRows(
        scope: SpaceScope,
        kind: SpaceKind,
        hasSearchQuery: Bool,
        now: Date
    ) -> Predicate<CachedSpace>? {
        let effective = hasSearchQuery ? SpaceScope.all : scope
        let types = kind.admittedRawValues

        switch effective {
        case .all:
            guard let types else { return nil }
            return ofKind(types)
        case .recent:
            return recentRows(types, cutoff: recentCutoff(now))
        case .unread:
            return possiblyUnreadRows(types)
        }
    }

    /// The start of the hour, less the recency window.
    ///
    /// Quantized rather than measured from the exact instant so the predicate is stable
    /// across a view's body evaluations — an ever-moving cutoff would mean a new fetch
    /// descriptor every time, which is the cost this exists to avoid. Erring up to an
    /// hour early only ever admits a row the in-memory pass then judges properly.
    static func recentCutoff(_ now: Date) -> Date {
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        return hour.addingTimeInterval(-SpaceScope.recentWindow)
    }

    // MARK: - Row predicates

    private static func ofKind(_ types: [String?]) -> Predicate<CachedSpace> {
        #Predicate<CachedSpace> { space in
            types.contains(space.spaceTypeRaw)
        }
    }

    /// Pinned rows are listed whatever the scope says, so they are exempted here too, or
    /// the fetch would drop rows the sidebar is obliged to show.
    private static func recentRows(
        _ types: [String?]?,
        cutoff: Date
    ) -> Predicate<CachedSpace> {
        guard let types else {
            return #Predicate<CachedSpace> { space in
                space.isPinned
                    || (space.lastActiveTime.flatMap { $0 >= cutoff } ?? false)
            }
        }
        return #Predicate<CachedSpace> { space in
            types.contains(space.spaceTypeRaw)
                && (space.isPinned
                    || (space.lastActiveTime.flatMap { $0 >= cutoff } ?? false))
        }
    }

    /// Everything the unread scope *could* list, standing in for the exact rule.
    ///
    /// `didFetchReadState` rather than the timestamp comparison it guards, because that
    /// comparison cannot share a predicate with anything — see the note above. So this
    /// admits every space whose read state has been fetched, and ``SidebarIndex`` discards
    /// the ones that turn out to be read. Correct, and no worse than the old
    /// fetch-everything behaviour even once every read state has landed: the unread scope
    /// is the one place this change does not also make much faster.
    private static func possiblyUnreadRows(_ types: [String?]?) -> Predicate<CachedSpace> {
        guard let types else {
            return #Predicate<CachedSpace> { space in
                space.isPinned
                    || space.didFetchReadState
                    || space.unreadCount + space.unreadThreadCount > 0
            }
        }
        return #Predicate<CachedSpace> { space in
            types.contains(space.spaceTypeRaw)
                && (space.isPinned
                    || space.didFetchReadState
                    || space.unreadCount + space.unreadThreadCount > 0)
        }
    }

    // MARK: - Count predicates

    /// Rows one option of the filter bar would show, for the counts in its menu.
    ///
    /// No pinned exemption, unlike the row query: the counts answer "how many rows would
    /// picking this produce", and ``SidebarIndex`` tallied them without one.
    ///
    /// - Returns: nil for the unread scope, which no single predicate can express, and nil
    ///   where nothing narrows. Use ``unreadByCounters(kind:mutedOnly:)`` together with
    ///   ``unreadByTimestamp()`` for the former — ``SidebarCounts`` does.
    static func count(
        scope: SpaceScope,
        kind: SpaceKind,
        mutedOnly: Bool = false,
        now: Date
    ) -> Predicate<CachedSpace>? {
        let types = kind.admittedRawValues
        switch scope {
        case .all:
            if types == nil, !mutedOnly { return nil }
            return countedAll(types, mutedOnly: mutedOnly)
        case .recent:
            return countedRecent(types, mutedOnly: mutedOnly, cutoff: recentCutoff(now))
        case .unread:
            return nil
        }
    }

    /// The half of the unread set the cached counters prove, filtered by kind and mute
    /// like any other count.
    static func unreadByCounters(
        kind: SpaceKind,
        mutedOnly: Bool = false
    ) -> Predicate<CachedSpace> {
        guard let types = kind.admittedRawValues else {
            return #Predicate<CachedSpace> { space in
                (!mutedOnly || (space.isMuted && !space.isPinned))
                    && space.unreadCount + space.unreadThreadCount > 0
            }
        }
        return #Predicate<CachedSpace> { space in
            types.contains(space.spaceTypeRaw)
                && (!mutedOnly || (space.isMuted && !space.isPinned))
                && space.unreadCount + space.unreadThreadCount > 0
        }
    }

    /// The other half: active since the read mark, which is the only unread a space with
    /// no cached history can show. Carries no kind or mute clause — it cannot — so callers
    /// apply those in memory over what it returns, which is a handful of rows.
    static func unreadByTimestamp() -> Predicate<CachedSpace> {
        #Predicate<CachedSpace> { space in
            space.didFetchReadState
                && (space.lastActiveTime.flatMap { active in
                    space.lastReadTime.flatMap { $0 < active }
                } ?? false)
        }
    }

    private static func countedAll(
        _ types: [String?]?,
        mutedOnly: Bool
    ) -> Predicate<CachedSpace> {
        guard let types else {
            return #Predicate<CachedSpace> { space in
                !mutedOnly || (space.isMuted && !space.isPinned)
            }
        }
        return #Predicate<CachedSpace> { space in
            types.contains(space.spaceTypeRaw)
                && (!mutedOnly || (space.isMuted && !space.isPinned))
        }
    }

    private static func countedRecent(
        _ types: [String?]?,
        mutedOnly: Bool,
        cutoff: Date
    ) -> Predicate<CachedSpace> {
        guard let types else {
            return #Predicate<CachedSpace> { space in
                (!mutedOnly || (space.isMuted && !space.isPinned))
                    && (space.lastActiveTime.flatMap { $0 >= cutoff } ?? false)
            }
        }
        return #Predicate<CachedSpace> { space in
            types.contains(space.spaceTypeRaw)
                && (!mutedOnly || (space.isMuted && !space.isPinned))
                && (space.lastActiveTime.flatMap { $0 >= cutoff } ?? false)
        }
    }
}
