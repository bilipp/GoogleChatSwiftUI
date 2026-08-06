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

    static let recentWindow: TimeInterval = 60 * 60 * 24 * 30

    func matches(_ space: CachedSpace, now: Date) -> Bool {
        switch self {
        case .all:
            return true
        case .unread:
            return space.unreadCount > 0 || space.hasUnread
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
