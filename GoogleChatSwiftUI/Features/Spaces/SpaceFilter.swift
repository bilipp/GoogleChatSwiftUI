import Foundation

/// Which slice of the space list the sidebar shows.
///
/// This account has 762 spaces, the overwhelming majority dormant DMs. A flat list
/// is unnavigable, so the default is activity-scoped and search reaches everything.
enum SpaceFilter: String, CaseIterable, Identifiable, Sendable {
    case recent
    case all
    case spaces
    case directMessages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .all: "All"
        case .spaces: "Spaces"
        case .directMessages: "Direct Messages"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .all: "tray.full"
        case .spaces: "number"
        case .directMessages: "person.2"
        }
    }

    /// A space counts as recent if it saw activity within this window.
    static let recentWindow: TimeInterval = 60 * 60 * 24 * 30

    func matches(_ space: CachedSpace, now: Date) -> Bool {
        switch self {
        case .all:
            return true
        case .recent:
            guard let active = space.lastActiveTime else { return false }
            return now.timeIntervalSince(active) <= Self.recentWindow
        case .spaces:
            return space.spaceType == .space || space.spaceType == .groupChat
        case .directMessages:
            return space.spaceType == .directMessage
        }
    }
}
