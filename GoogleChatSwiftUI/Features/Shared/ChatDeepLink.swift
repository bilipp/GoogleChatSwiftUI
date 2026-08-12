import Foundation

/// A `chat.google.com` URL, read as the Chat resource names it points at.
///
/// The mapping is documented nowhere, but Chat states it itself: paste a message link
/// into a conversation and the message comes back carrying a `CHAT_SPACE` rich-link
/// annotation with both the URL and the `spaces/…` names it resolved to. Every example
/// agrees on one shape —
///
///     https://chat.google.com/room/AAQAA_vg0rg/nxaMihFK0bw/MBJaRMLeD4s?cls=10
///       space    spaces/AAQAA_vg0rg
///       thread   spaces/AAQAA_vg0rg/threads/nxaMihFK0bw
///       message  spaces/AAQAA_vg0rg/messages/nxaMihFK0bw.MBJaRMLeD4s
///
/// — so a message id is its thread's id and its own joined by a dot, and the link
/// spells that same pair with a slash. `room` addresses a space and `dm` a direct
/// message; either way the segment after it is the space id unchanged.
///
/// Parsing is deliberately generous, because over-matching is the cheap mistake here:
/// a link whose space this account cannot see is handed back to the browser anyway, so
/// the only cost of recognising one segment too many is a URL that opens where it
/// always did. Under-matching, by contrast, sends the reader to a browser tab to look
/// at a conversation that is already open behind it.
nonisolated struct ChatDeepLink: Equatable, Sendable {
    /// The conversation, e.g. `spaces/AAQAA_vg0rg`.
    let spaceName: String
    /// The thread, when the link names one.
    let threadName: String?
    /// The message, when the link names one.
    let messageName: String?

    /// The words Chat's web routes use in front of a space id. `chat` covers both
    /// `/app/chat/{space}` and the older `#chat/space/{space}` fragment form.
    private static let routeWords: Set<String> = ["room", "dm", "space", "chat"]

    init?(url: URL) {
        guard url.host()?.lowercased() == "chat.google.com" else { return nil }

        // Path and fragment concatenated: the fragment form keeps the whole route after
        // the `#`, with nothing but `/u/0/` in the path itself.
        var segments = url.pathComponents.filter { $0 != "/" }
        if let fragment = url.fragment(percentEncoded: false) {
            segments += fragment.split(separator: "/").map(String.init)
        }

        // The *last* routing word wins, so `app/chat/AAAA` and `#chat/space/AAAA` both
        // land on the id rather than on the word in front of it. A `/u/0/` prefix needs
        // no special handling for the same reason.
        guard let word = segments.lastIndex(where: { Self.routeWords.contains($0.lowercased()) })
        else { return nil }

        let rest = segments[(word + 1)...].filter(Self.isIdentifier)
        guard let space = rest.first else { return nil }
        spaceName = "spaces/\(space)"

        guard let thread = rest.dropFirst().first else {
            threadName = nil
            messageName = nil
            return
        }
        threadName = "spaces/\(space)/threads/\(thread)"
        if let message = rest.dropFirst(2).first {
            messageName = "spaces/\(space)/messages/\(thread).\(message)"
        } else {
            messageName = nil
        }
    }

    /// Chat ids are URL-safe base64: letters, digits, `-`, `_`. Anything else is a
    /// route this app does not recognise rather than something to navigate to.
    private static func isIdentifier(_ segment: String) -> Bool {
        guard !segment.isEmpty, !routeWords.contains(segment.lowercased()) else { return false }
        return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: - Building one

    /// The link to hand someone else for a message — the same URL the web client's own
    /// "Copy link" produces, so it opens in their browser and in this app.
    ///
    /// - Parameter spaceType: what chooses the word. `dm` for a one-to-one and `room`
    ///   for everything else — a group chat included, which is the one that has to be
    ///   checked rather than reasoned about: group chats are named from their members
    ///   like direct messages, and only their ids give them away as spaces.
    /// - Parameter spaceURI: `Space.spaceUri`, Google's own "URI for a user to access
    ///   the space", preferred when there is one. There is currently never one —
    ///   `spaces.list` does not return the field — so this is insurance against Chat
    ///   changing its own URLs rather than something the app relies on.
    ///
    /// Chat appends `?cls=10` to the links it copies. Omitted here: it tags where the
    /// click came from rather than saying anything about where it goes, and links
    /// without it — including ones people have pasted into this account's own
    /// conversations — resolve identically.
    static func messageURL(
        for messageName: String,
        spaceURI: String?,
        spaceType: ChatSpace.SpaceType?
    ) -> URL? {
        // `spaces/{space}/messages/{thread}.{message}` is the only shape Chat issues,
        // and its two halves are exactly the last two segments of the link. A
        // locally-composed placeholder is keyed by a client id with no dot in it, and
        // has no link to give until the server has named it.
        let parts = messageName.split(separator: "/")
        guard parts.count == 4, parts[0] == "spaces", parts[2] == "messages" else { return nil }
        let ids = parts[3].split(separator: ".")
        guard ids.count == 2 else { return nil }

        guard
            var components = conversationURL(
                spaceID: String(parts[1]),
                spaceURI: spaceURI,
                spaceType: spaceType
            )
        else { return nil }
        components.path += "/\(ids[0])/\(ids[1])"
        return components.url
    }

    /// The link to hand someone else for a whole conversation, by the same rules as
    /// ``messageURL(for:spaceURI:spaceType:)`` — a message link with its last two
    /// segments left off, which is exactly what the web client copies for a space.
    static func spaceURL(
        for spaceName: String,
        spaceURI: String?,
        spaceType: ChatSpace.SpaceType?
    ) -> URL? {
        let parts = spaceName.split(separator: "/")
        guard parts.count == 2, parts[0] == "spaces", isIdentifier(String(parts[1]))
        else { return nil }
        return conversationURL(spaceID: String(parts[1]), spaceURI: spaceURI, spaceType: spaceType)?
            .url
    }

    /// The conversation half of a link — everything up to and including the space id,
    /// which a message link then names a thread and a message under.
    private static func conversationURL(
        spaceID: String,
        spaceURI: String?,
        spaceType: ChatSpace.SpaceType?
    ) -> URLComponents? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "chat.google.com"
        var path = "/\(spaceType == .directMessage ? "dm" : "room")/\(spaceID)"

        if let spaceURI, let uri = URLComponents(string: spaceURI), !uri.path.isEmpty {
            if let scheme = uri.scheme { components.scheme = scheme }
            if let host = uri.host { components.host = host }
            path = uri.path
        }

        // A query on the stored URI is dropped with it: `?cls=` tags where a click came
        // from, and one copied from this account's sidebar would be claiming the reader's
        // click came from here.
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components
    }
}

/// What a ``ChatDeepLink`` turns out to point at, once checked against the cache.
nonisolated enum ChatLinkDestination: Equatable, Sendable {
    /// No such conversation in this account's cache — the link belongs to the browser.
    case unknownSpace
    /// Open the conversation; the link named nothing more specific.
    case space
    /// Open the conversation and scroll its transcript to this message.
    case message(String)
    /// Open this thread, and go to this message within it. A reply in a threaded space is
    /// not in the transcript, so the thread pane holds the only position there is for it —
    /// which is why the message travels with the thread rather than being dropped here.
    /// Nil where the link named a thread and no message in it.
    case thread(String, message: String?)
    /// The conversation is cached but the message it names is not, which downloaded
    /// history not reaching back far enough is the usual reason for.
    case uncachedMessage
}
