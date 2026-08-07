import SwiftUI

/// Menu-bar commands and their keyboard shortcuts.
///
/// Actions are dispatched through `NotificationCenter` rather than by reaching into
/// the session model: `Commands` is built at the `Scene` level, above the view that
/// owns the session, so it has no way to hold a reference to it.
struct ChatCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Refresh Conversations") {
                NotificationCenter.default.post(name: .chatRefreshSpaces, object: nil)
            }
            .keyboardShortcut("r")

            Button("Mark All as Read") {
                NotificationCenter.default.post(name: .chatMarkAllRead, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            // Acts on the open conversation, and closes it — see
            // `ChatSessionModel.markUnread`. Ignored when nothing is open, like the
            // thread panel's shortcut in a space that has no threads.
            Button("Mark as Unread") {
                NotificationCenter.default.post(name: .chatMarkUnread, object: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            // Unread thread replies are unreachable from the transcript, so the panel
            // that lists them earns a shortcut of its own rather than only a button.
            Button("Show Threads") {
                NotificationCenter.default.post(name: .chatToggleThreads, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            // No "Search Messages" item: `.searchable` installs its own Find entry
            // with ⌘F, and a second one here would shadow it.
            //
            // ⌘⇧K rather than a second Find-flavoured shortcut: this is the
            // jump-to-conversation gesture other chat clients use, and it reads as
            // navigation — which is what it does — instead of as text search.
            Button("Search Conversations") {
                NotificationCenter.default.post(name: .chatFocusSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let chatRefreshSpaces = Notification.Name("chatRefreshSpaces")
    static let chatMarkAllRead = Notification.Name("chatMarkAllRead")
    static let chatMarkUnread = Notification.Name("chatMarkUnread")
    static let chatFocusSearch = Notification.Name("chatFocusSearch")
    static let chatToggleThreads = Notification.Name("chatToggleThreads")
}
