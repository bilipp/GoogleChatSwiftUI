import SwiftUI

/// Opens a message in whichever conversation it lives in, from wherever it was named.
///
/// An environment action for the same reason ``OpenDirectMessageAction`` is one: the surface
/// asking is inside the transcript, and going to a message in *another* conversation takes
/// more than selecting a space — the sidebar's filters have to make room for the row first,
/// and only `SpacesListView` knows how. Everything below simply asks.
///
/// This exists because of forwards. A reply can only quote a message in the conversation it
/// was posted in, so the transcript can reach the original itself. A forward carries a message
/// out of another space entirely — see ``ForwardedMessage`` — and that space may be one this
/// account has never been in, which is why the handler is allowed to decline.
nonisolated struct OpenChatMessageAction {
    private let handler: @MainActor (String, String) -> Void

    init(handler: @escaping @MainActor (String, String) -> Void) {
        self.handler = handler
    }

    /// - Parameter messageName: Chat message resource name, e.g.
    ///   `spaces/AAAA/messages/BBBB.CCCC`.
    /// - Parameter spaceName: the conversation it is in. Passed separately rather than parsed
    ///   back out of the message name, because the caller was told it by Chat and a name is
    ///   not a promise about its own shape.
    @MainActor
    func callAsFunction(_ messageName: String, in spaceName: String) {
        handler(messageName, spaceName)
    }
}

extension EnvironmentValues {
    /// Does nothing by default, so a view hosted outside the sidebar — a preview, a test —
    /// renders rather than crashes.
    @Entry var openChatMessage = OpenChatMessageAction { _, _ in }
}
