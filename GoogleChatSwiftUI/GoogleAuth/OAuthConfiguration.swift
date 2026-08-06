import Foundation

/// Static OAuth parameters for the GoogleChatSwiftUI installed app.
///
/// The client ID is deliberately checked in. Installed-app OAuth clients (Google's
/// "iOS" type) are issued without a client secret precisely because the binary is
/// distributable and cannot keep one — security comes from PKCE plus the fact that
/// the redirect URI is bound to this app's bundle ID. See RFC 8252 §8.
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
    ]

    static var scopeString: String { scopes.joined(separator: " ") }

    // MARK: - Google Cloud project

    static let gcpProjectID = "YOUR_PROJECT_ID"
    static let pubSubSubscription = "projects/\(gcpProjectID)/subscriptions/chat-events-mac"
    static let pubSubTopic = "projects/\(gcpProjectID)/topics/chat-events"
}
