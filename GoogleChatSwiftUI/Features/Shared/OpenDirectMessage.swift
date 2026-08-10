import SwiftUI

/// Opens the one-to-one conversation with a person, from wherever that person is shown.
///
/// An environment action rather than a method on the session, for the same reason
/// `\.openURL` is overridden rather than reached into: the surfaces that show a person —
/// a bubble's avatar, the name above a run of messages, a reply in a thread — are
/// nowhere near the sidebar that owns navigation, and opening a conversation from
/// outside the sidebar takes more than selecting it. The filters have to make room for
/// the row first. Only `SpacesListView` knows how to do that, so it is what installs
/// this, and everything below simply asks.
nonisolated struct OpenDirectMessageAction {
    private let handler: @MainActor (String) -> Void

    init(handler: @escaping @MainActor (String) -> Void) {
        self.handler = handler
    }

    /// - Parameter userID: Chat user resource name, e.g. `users/1234567890`.
    @MainActor
    func callAsFunction(_ userID: String) {
        handler(userID)
    }
}

extension EnvironmentValues {
    /// Does nothing by default, so a view hosted outside the sidebar — a preview, a
    /// test — renders rather than crashes.
    @Entry var openDirectMessage = OpenDirectMessageAction { _ in }
}

extension View {
    /// Makes a person's avatar or name the way into a chat with them.
    ///
    /// - Parameter userID: nil where there is no chat to open — your own messages, and
    ///   apps, which have no DM Chat will create — and then this leaves the view exactly
    ///   as it was rather than offering a click that would fail.
    /// - Parameter name: who it is, for the tooltip and for VoiceOver. The click is
    ///   otherwise unannounced, and an avatar that silently navigates is worse than one
    ///   that does nothing.
    func opensDirectMessage(with userID: String?, named name: String) -> some View {
        modifier(DirectMessageTarget(userID: userID, name: name))
    }
}

private struct DirectMessageTarget: ViewModifier {
    let userID: String?
    let name: String

    @Environment(\.openDirectMessage) private var openDirectMessage

    func body(content: Content) -> some View {
        if let userID {
            Button {
                openDirectMessage(userID)
            } label: {
                content
            }
            // Plain, because the thing being clicked is already drawn: a bordered
            // button around an avatar would put a control where a face should be.
            .buttonStyle(.plain)
            // The only standing cue that this is clickable at all. A hover highlight
            // was the alternative and is worse here — it would reflow nothing but
            // would make every avatar in a scrolling transcript twitch under the
            // cursor on the way past.
            .pointerStyle(.link)
            .help("Message \(name)")
            .accessibilityLabel("Message \(name)")
        } else {
            content
        }
    }
}
