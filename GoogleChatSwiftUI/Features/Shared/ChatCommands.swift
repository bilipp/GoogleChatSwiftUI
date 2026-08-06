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
        }

        CommandGroup(after: .textEditing) {
            Button("Search Conversations") {
                NotificationCenter.default.post(name: .chatFocusSearch, object: nil)
            }
            .keyboardShortcut("f")
        }
    }
}

extension Notification.Name {
    static let chatRefreshSpaces = Notification.Name("chatRefreshSpaces")
    static let chatMarkAllRead = Notification.Name("chatMarkAllRead")
    static let chatFocusSearch = Notification.Name("chatFocusSearch")
}
