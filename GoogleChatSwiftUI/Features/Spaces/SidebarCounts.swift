import Foundation
import SwiftData

/// The row counts the filter bar shows beside each option.
///
/// Counted in SQLite rather than by walking the space list, because the sidebar no longer
/// *has* the whole list to walk — see ``SpaceQueries``. A `fetchCount` costs about 0.25ms
/// against the ~52ms a full fetch of 769 rows takes, so all seven numbers together are
/// cheaper than one row of the list used to be.
///
/// Exact, unlike the row query, which is allowed to be generous. These are numbers shown
/// to the user, and the point of them is that the effect of picking an option is visible
/// before picking it.
enum SidebarCounts {
    /// How many rows one (scope, kind) pair would list.
    ///
    /// - Parameter mutedOnly: restrict to muted, unpinned rows — what the Muted item in
    ///   the menu reports. Pinned rows are excluded there because they are listed whatever
    ///   the toggle says, so counting them would promise rows it cannot reveal.
    static func count(
        scope: SpaceScope,
        kind: SpaceKind,
        mutedOnly: Bool = false,
        now: Date,
        in context: ModelContext
    ) throws -> Int {
        // The unread scope is the one that cannot be asked as a single question: the two
        // halves of `CachedSpace.hasUnread` will not share a predicate. So both are
        // fetched and merged by name — overlapping sets, hence names rather than two
        // counts added up.
        guard scope == .unread else {
            var descriptor = FetchDescriptor<CachedSpace>()
            descriptor.predicate = SpaceQueries.count(
                scope: scope,
                kind: kind,
                mutedOnly: mutedOnly,
                now: now
            )
            return try context.fetchCount(descriptor)
        }

        let counted = try context.fetch(
            FetchDescriptor<CachedSpace>(
                predicate: SpaceQueries.unreadByCounters(kind: kind, mutedOnly: mutedOnly)
            )
        )
        var names = Set(counted.map(\.name))

        // This half carries no kind or mute clause — it cannot — so they are applied here,
        // over the handful of rows that are unread by timestamp alone.
        let byTimestamp = try context.fetch(
            FetchDescriptor<CachedSpace>(predicate: SpaceQueries.unreadByTimestamp())
        )
        for space in byTimestamp where kind.matches(space) {
            guard !mutedOnly || (space.isMuted && !space.isPinned) else { continue }
            names.insert(space.name)
        }
        return names.count
    }
}
