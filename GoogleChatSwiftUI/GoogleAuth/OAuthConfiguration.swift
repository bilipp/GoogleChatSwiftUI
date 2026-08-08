import Foundation

/// Static OAuth parameters for the GoogleChatSwiftUI installed app.
///
/// The three per-person values come from `Config/Base.xcconfig`, which an optional,
/// gitignored `Config/Secrets.xcconfig` overrides — see `docs/SETUP.md`. They reach
/// the binary through `Config/Info.plist`, so a checkout with no `Secrets.xcconfig`
/// still builds; it just carries placeholders and reports ``isConfigured`` as `false`.
///
/// There is no client secret among them, and none is missing. Installed-app OAuth
/// clients (Google's "iOS" type) are issued without one precisely because the binary
/// is distributable and cannot keep a secret — security comes from PKCE plus the fact
/// that the redirect URI is bound to this app's bundle ID. See RFC 8252 §8.
nonisolated enum OAuthConfiguration {
    static let clientID = infoValue("GoogleOAuthClientID")

    /// Reverse-DNS form of the client ID, used as the redirect URL scheme.
    static let redirectScheme = infoValue("GoogleOAuthRedirectScheme")

    static let redirectURI = "\(redirectScheme):/oauth2redirect"

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Everything the full client needs, requested up front so the user consents once.
    ///
    /// `pubsub` is what lets the app pull Workspace Events straight from Cloud Pub/Sub
    /// with the signed-in user's own credentials, rather than standing up a backend.
    static let scopes: [String] = [
        "https://www.googleapis.com/auth/chat.spaces",
        "https://www.googleapis.com/auth/chat.messages",
        "https://www.googleapis.com/auth/chat.messages.reactions",
        "https://www.googleapis.com/auth/chat.memberships",
        "https://www.googleapis.com/auth/chat.users.readstate",
        "https://www.googleapis.com/auth/chat.users.sections",
        "https://www.googleapis.com/auth/chat.customemojis.readonly",
        "https://www.googleapis.com/auth/pubsub",
        "https://www.googleapis.com/auth/userinfo.profile",
        // Chat returns user IDs but never display names — not in memberships, not on
        // message senders. Resolving `users/123` to a human name means reading the
        // Workspace directory, which is what this scope is for. Without it every DM
        // is titled "Direct message" and every sender reads "Unknown".
        "https://www.googleapis.com/auth/directory.readonly",
    ]

    static var scopeString: String { scopes.joined(separator: " ") }

    // MARK: - Google Cloud project

    static let gcpProjectID = infoValue("GCPProjectID")
    static let pubSubSubscription = "projects/\(gcpProjectID)/subscriptions/chat-events-mac"
    static let pubSubTopic = "projects/\(gcpProjectID)/topics/chat-events"

    // MARK: - Reading the build configuration

    /// `false` when the app is still carrying the placeholders from `Base.xcconfig`,
    /// which is the state of any checkout without a `Config/Secrets.xcconfig`.
    /// Sign-in would fail against Google with an opaque error, so callers check this
    /// first and say what is actually wrong.
    static var isConfigured: Bool {
        ![clientID, redirectScheme, gcpProjectID].contains {
            $0.isEmpty || $0.contains("YOUR_")
        }
    }

    private static func infoValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}
