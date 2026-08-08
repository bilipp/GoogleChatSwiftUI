import Foundation

/// Static OAuth parameters for the GoogleChatSwiftUI installed app.
///
/// These three values are placeholders — point them at your own Google Cloud project
/// before the app will sign in. `docs/SETUP.md` walks through creating it.
///
/// There is no client secret to fill in, and none is missing. Installed-app OAuth
/// clients (Google's "iOS" type) are issued without one precisely because the binary
/// is distributable and cannot keep a secret — security comes from PKCE plus the fact
/// that the redirect URI is bound to this app's bundle ID. See RFC 8252 §8.
nonisolated enum OAuthConfiguration {
    static let clientID = "YOUR_NUMBER-YOUR_SUFFIX.apps.googleusercontent.com"

    /// Reverse-DNS form of the client ID, used as the redirect URL scheme.
    static let redirectScheme = "com.googleusercontent.apps.YOUR_NUMBER-YOUR_SUFFIX"

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

    static let gcpProjectID = "YOUR_PROJECT_ID"
    static let pubSubSubscription = "projects/\(gcpProjectID)/subscriptions/chat-events-mac"
    static let pubSubTopic = "projects/\(gcpProjectID)/topics/chat-events"
}
