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
        // Names the Pub/Sub subscription this install pulls from. Everyone signed in
        // to the same Cloud project shares one topic, and a Pub/Sub subscription
        // load-balances across its pullers — so a single shared subscription would
        // hand each event to whichever colleague happened to ask first. The address
        // is what makes the queue per-person; see `pubSubSubscription(for:)`.
        "https://www.googleapis.com/auth/userinfo.email",
        // Chat returns user IDs but never display names — not in memberships, not on
        // message senders. Resolving `users/123` to a human name means reading the
        // Workspace directory, which is what this scope is for. Without it every DM
        // is titled "Direct message" and every sender reads "Unknown".
        "https://www.googleapis.com/auth/directory.readonly",
    ]

    static var scopeString: String { scopes.joined(separator: " ") }

    // MARK: - Google Cloud project

    static let gcpProjectID = infoValue("GCPProjectID")
    static let pubSubTopic = "projects/\(gcpProjectID)/topics/chat-events"

    /// The Pub/Sub subscription this install pulls from, one per person.
    ///
    /// Chat publishes every subscriber's events into the one topic above, and a
    /// Pub/Sub subscription distributes its backlog across whoever is pulling it.
    /// One shared subscription therefore does not mean "everyone sees everything" —
    /// it means each event is delivered to exactly one colleague, at random. Deriving
    /// the name from the signed-in address gives each person their own queue.
    ///
    /// The subscription is not created here. It has to exist already, which keeps the
    /// grant each person needs down to `roles/pubsub.subscriber` on their own
    /// subscription rather than permission to create resources in the project. See
    /// `docs/SETUP.md`.
    static func pubSubSubscription(for emailAddress: String) -> String {
        "projects/\(gcpProjectID)/subscriptions/\(subscriptionID(for: emailAddress))"
    }

    /// Local part of the address, reduced to characters Pub/Sub accepts in an ID.
    ///
    /// Pub/Sub requires a leading letter and allows only letters, digits, dashes,
    /// underscores, periods, tildes, percents and pluses. The `chat-events-` prefix
    /// supplies the leading letter, so the local part only has to be narrowed — and
    /// it is narrowed to `[a-z0-9-]` rather than to what Pub/Sub strictly permits, so
    /// that the name is predictable enough to type into `gcloud` up front:
    /// `p.bischoff@innoloft.com` becomes `chat-events-p-bischoff`.
    static func subscriptionID(for emailAddress: String) -> String {
        let localPart = emailAddress.split(separator: "@").first ?? ""
        let sanitized = localPart.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        return "chat-events-" + String(sanitized)
    }

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
