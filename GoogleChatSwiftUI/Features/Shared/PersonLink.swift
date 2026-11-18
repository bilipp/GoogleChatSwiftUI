import Foundation

/// The link a mention carries, so clicking a name in a message opens a chat with them.
///
/// A URL rather than a tap handler because mentions are runs inside one `Text`, which
/// has no per-run actions — only links, routed through `\.openURL`. The scheme is
/// private to this app: `SpacesListView` claims it before any URL reaches the system.
nonisolated enum PersonLink {
    static let scheme = "gchat-person"

    /// - Parameter userID: Chat user resource name, e.g. `users/1234567890`.
    static func url(for userID: String) -> URL? {
        // `users/all` is everyone in the space, not someone to message.
        guard userID != MentionCandidate.everyoneName else { return nil }
        return URL(string: "\(scheme):\(userID)")
    }

    /// The user resource name a person link points at, or nil for any other URL.
    static func userID(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let id = String(url.absoluteString.dropFirst(scheme.count + 1))
        return id.hasPrefix("users/") ? id : nil
    }
}
