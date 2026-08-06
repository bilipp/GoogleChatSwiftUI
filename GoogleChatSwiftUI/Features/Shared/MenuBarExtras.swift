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
    @Query(filter: #Predicate<CachedSpace> { $0.unreadCount > 0 },
           sort: [SortDescriptor(\CachedSpace.lastActiveTime, order: .reverse)])
    private var unreadSpaces: [CachedSpace]

    var body: some View {
        if case .signedIn = auth.state {
            if unreadSpaces.isEmpty {
                Text("No unread messages")
            } else {
                Text("\(totalUnread) unread in \(unreadSpaces.count) conversation\(unreadSpaces.count == 1 ? "" : "s")")
                Divider()
                // Capped: an unbounded menu of 700 rows is unusable, and the top few
                // by recency are what anyone actually wants from a menu-bar peek.
                ForEach(unreadSpaces.prefix(10)) { space in
                    Button("\(space.title) (\(space.unreadCount))") {
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
        unreadSpaces.reduce(0) { $0 + $1.unreadCount }
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
