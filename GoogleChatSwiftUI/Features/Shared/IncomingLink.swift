import AppKit
import Observation

/// A request from outside the app to open a conversation, and optionally to start a
/// message in it.
///
/// Arrives as `gchat://room/{space}/{thread}?draft=…` — the path of a `chat.google.com`
/// link under the app's own scheme, because an `https` link always goes to the browser:
/// macOS hands a web URL to an app only through associated domains, which only Google
/// could set up for `chat.google.com`. Everything after the scheme is read by
/// ``ChatDeepLink``, so the two link forms can never disagree about where they point.
/// An `https://chat.google.com/…` URL is accepted too, for anything that hands one over
/// directly.
///
/// The draft is only ever placed in the composer, never sent: whoever built the link is
/// not the one deciding the message goes out.
nonisolated struct IncomingLink: Equatable, Sendable {
    static let scheme = "gchat"

    let link: ChatDeepLink
    /// The web form of the same link, for when this account has no such conversation
    /// and the browser is the only place left to open it.
    let webURL: URL
    let draft: String?

    init?(url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let draft = components.queryItems?
            .first { $0.name == "draft" }?
            .value
            .flatMap { $0.isEmpty ? nil : $0 }

        switch components.scheme?.lowercased() {
        case Self.scheme:
            // `gchat://room/AAAA/…` parses with `room` as the host; it is the first
            // segment of the web path, not a server.
            let route = (components.host ?? "") + components.path
            components = URLComponents()
            components.scheme = "https"
            components.host = "chat.google.com"
            components.path = route.hasPrefix("/") ? route : "/" + route
        case "https", "http":
            components.queryItems = nil
        default:
            return nil
        }

        guard let webURL = components.url, let link = ChatDeepLink(url: webURL) else {
            return nil
        }
        self.link = link
        self.webURL = webURL
        self.draft = draft
    }
}

/// Holds an ``IncomingLink`` until the sidebar can act on it.
///
/// Buffered for the same reason ``NotificationRouter`` buffers a clicked notification:
/// opening a link can launch the app, and the URL then arrives while sign-in is still
/// restoring and there is no session to reveal anything in.
@MainActor
@Observable
final class IncomingLinkRouter {
    static let shared = IncomingLinkRouter()

    private(set) var pending: IncomingLink?

    func receive(_ url: URL) {
        guard let incoming = IncomingLink(url: url) else { return }
        pending = incoming
        // A window that was closed or minimised is not brought back by the system for a
        // URL any more than for a notification.
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows
            .first { $0.canBecomeMain }?
            .makeKeyAndOrderFront(nil)
    }

    /// Takes the pending link and clears it, so one open opens one conversation.
    func claim() -> IncomingLink? {
        defer { pending = nil }
        return pending
    }
}
