import SwiftUI

/// Menu-bar commands and their keyboard shortcuts.
///
/// Actions are dispatched through `NotificationCenter` rather than by reaching into
/// the session model: `Commands` is built at the `Scene` level, above the view that
/// owns the session, so it has no way to hold a reference to it.
struct ChatCommands: Commands {
    var body: some Commands {
        // Replaces File ▸ New Window: a second window would be a second copy of the
        // same session, and ⌘N is where a chat client keeps "start a conversation".
        CommandGroup(replacing: .newItem) {
            Button("New Conversation…") {
                NotificationCenter.default.post(name: .chatNewConversation, object: nil)
            }
            .keyboardShortcut("n")
        }

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
            // The only keyboard route to message search. `.searchable` puts the field
            // in the toolbar but installs no Find command of its own — verified against
            // a running build: the Edit menu has no Find item, and ⌘F focuses nothing —
            // so without this the field is reachable by mouse alone.
            //
            // ⌘⇧F pairs with the ⌘⇧K below, and stays clear of the plain ⌘F that a
            // future find-within-transcript would want.
            Button("Search Messages") {
                NotificationCenter.default.post(name: .chatFocusMessageSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            // ⌘⇧K rather than another Find-flavoured shortcut: this is the
            // jump-to-conversation gesture other chat clients use, and it reads as
            // navigation — which is what it does — instead of as text search.
            Button("Search Conversations") {
                NotificationCenter.default.post(name: .chatFocusSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}

/// `nonisolated` because ``ChatStore`` posts from its own actor: under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` these constants would otherwise be
/// main-actor isolated and unreachable from there.
nonisolated extension Notification.Name {
    static let chatNewConversation = Notification.Name("chatNewConversation")
    static let chatRefreshSpaces = Notification.Name("chatRefreshSpaces")
    static let chatMarkAllRead = Notification.Name("chatMarkAllRead")
    static let chatMarkUnread = Notification.Name("chatMarkUnread")
    static let chatFocusSearch = Notification.Name("chatFocusSearch")
    static let chatFocusMessageSearch = Notification.Name("chatFocusMessageSearch")
    static let chatToggleThreads = Notification.Name("chatToggleThreads")
    /// A `CachedUser` row was written. Posted by ``ChatStore`` beside the save, so a
    /// new directory writer cannot forget to invalidate ``DirectoryCache``.
    static let chatDirectoryChanged = Notification.Name("chatDirectoryChanged")
}
