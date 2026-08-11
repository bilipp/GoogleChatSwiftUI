import Foundation

/// How much of the conversation list to show.
///
/// Split from `SpaceKind` on purpose. A single five-way control mixed two unrelated
/// questions — "how recent?" and "what type?" — so picking "Spaces" silently threw
/// away the recency limit and the list jumped from 40 rows to 700. Two independent
/// axes are both clearer and composable.
enum SpaceScope: String, CaseIterable, Identifiable, Sendable {
    case unread
    case recent
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .recent: "Recent"
        case .all: "All time"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "circle.fill"
        case .recent: "clock"
        case .all: "infinity"
        }
    }

    /// Explains what the scope actually does, since "Recent" alone does not say
    /// how recent.
    var caption: String {
        switch self {
        case .unread: "With new messages"
        case .recent: "Active in the last 30 days"
        case .all: "Every conversation"
        }
    }

    nonisolated static let recentWindow: TimeInterval = 60 * 60 * 24 * 30

    func matches(_ space: CachedSpace, now: Date) -> Bool {
        switch self {
        case .all:
            return true
        case .unread:
            // Threads count: after a space is opened they are the only unread it has.
            return space.unreadCount > 0 || space.hasUnread || space.unreadThreadCount > 0
        case .recent:
            guard let active = space.lastActiveTime else { return false }
            return now.timeIntervalSince(active) <= Self.recentWindow
        }
    }
}

/// Which kinds of conversation to include.
enum SpaceKind: String, CaseIterable, Identifiable, Sendable {
    case all
    case spaces
    case directMessages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Everything"
        case .spaces: "Spaces only"
        case .directMessages: "Direct messages only"
        }
    }

    /// Short form for the filter button, where the full title is too long.
    var shortTitle: String {
        switch self {
        case .all: "Everything"
        case .spaces: "Spaces"
        case .directMessages: "DMs"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.2"
        case .spaces: "number"
        case .directMessages: "person.2"
        }
    }

    func matches(_ space: CachedSpace) -> Bool {
        switch self {
        case .all:
            return true
        case .spaces:
            return space.spaceType == .space || space.spaceType == .groupChat
        case .directMessages:
            return space.spaceType == .directMessage
        }
    }
}

extension SpaceKind {
    /// The `CachedSpace.spaceTypeRaw` values this kind admits, or nil where it admits
    /// every one of them and no clause is wanted at all.
    ///
    /// Exists so the kind axis can travel into a SwiftData predicate as a captured list
    /// rather than as one hand-written predicate per (scope, kind) pair — see
    /// ``SpaceQueries``.
    ///
    /// ``all`` returns nil rather than a list of every case *including* `nil`, which was
    /// the first attempt and was wrong: SQL's `IN` never matches NULL, so a space whose
    /// `spaceType` the API omitted would be filtered out by the very option meaning
    /// "everything". Its absence has to drop the clause, not widen it.
    nonisolated var admittedRawValues: [String?]? {
        switch self {
        case .all:
            return nil
        case .spaces:
            return [ChatSpace.SpaceType.space.rawValue, ChatSpace.SpaceType.groupChat.rawValue]
        case .directMessages:
            return [ChatSpace.SpaceType.directMessage.rawValue]
        }
    }
}
