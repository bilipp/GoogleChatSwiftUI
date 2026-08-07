import SwiftData
import SwiftUI

/// Menu-bar icon carrying the unread count.
///
/// Reads the cache directly rather than the session model: the menu-bar scene is a
/// separate scene with no access to the window's session, and unread state is already
/// persisted, so querying it is simpler than plumbing state across scenes.
struct MenuBarLabel: View {
    @Environment(AuthModel.self) private var auth

    var body: some View {
        // Symbol variant rather than a text badge: the menu bar is tight and a
        // number there competes with every other item for space.
        Image(systemName: "bubble.left.and.bubble.right")
            .symbolVariant(.fill)
    }
}

struct MenuBarContent: View {
    @Environment(AuthModel.self) private var auth
    /// Muted conversations are left out: the menu-bar peek is a "what needs me?"
    /// list, and a muted space is by definition not that.
    ///
    /// Unread thread replies count too: once a space has been opened they are the
    /// only unread left in it, and a menu that ignored them would call a conversation
    /// clear while replies sit unread inside it.
    @Query(
        filter: #Predicate<CachedSpace> { space in
            !space.isMuted && (space.unreadCount > 0 || space.unreadThreadReplyCount > 0)
        },
        sort: [SortDescriptor(\CachedSpace.lastActiveTime, order: .reverse)]
    )
    private var unreadSpaces: [CachedSpace]

    /// Pinned first, then by recency. Sorted here rather than in the query because
    /// `Bool` is not `Comparable`, so it cannot be a `SortDescriptor` key path.
    private var rankedUnread: [CachedSpace] {
        unreadSpaces.filter(\.isPinned) + unreadSpaces.filter { !$0.isPinned }
    }

    var body: some View {
        if case .signedIn = auth.state {
            if unreadSpaces.isEmpty {
                Text("No unread messages")
            } else {
                Text("\(totalUnread) unread in \(unreadSpaces.count) conversation\(unreadSpaces.count == 1 ? "" : "s")")
                Divider()
                // Capped: an unbounded menu of 700 rows is unusable, and the top few
                // by recency are what anyone actually wants from a menu-bar peek.
                ForEach(rankedUnread.prefix(10)) { space in
                    Button("\(space.title) (\(space.totalUnread))") {
                        activateApp()
                    }
                }
            }
            Divider()
        }

        Button("Open GoogleChatSwiftUI") { activateApp() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var totalUnread: Int {
        unreadSpaces.reduce(0) { $0 + $1.totalUnread }
    }

    /// Brings the main window forward. Selecting the specific space from here would
    /// need cross-scene state the app does not currently carry.
    private func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows
            .first { $0.canBecomeMain }?
            .makeKeyAndOrderFront(nil)
    }
}
