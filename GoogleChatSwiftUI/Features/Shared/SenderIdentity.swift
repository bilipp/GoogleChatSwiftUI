import Foundation

/// Who a cached message came from, as the app should show it.
///
/// One type rather than the same fallbacks written out again in the bubble, the thread
/// list, a search row and a quote — they have to agree, and the rules are not guessable
/// from any one of them.
///
/// The rules exist because of what Chat will say about a sender. Under user
/// authentication a `Message.sender` is a resource name and a type: `displayName` is
/// documented as output-only and simply does not arrive, for colleagues or for apps. So
/// every name in this app is resolved somewhere else — people through the People API,
/// and apps not at all, because People has no entry for a Chat app or an incoming
/// webhook. That is the whole reason an app sender needs its own case here: it is not a
/// person the directory is slow about, it is a poster that no request will ever name.
/// `nonisolated`, like the DTOs and unlike the models it is built from: the notification
/// banner is assembled inside an actor and needs the same answers the transcript shows.
/// Only the initialiser that reads a `CachedMessage` stays on the main actor — see the
/// extension below, and ``MentionCandidate`` for the same split.
nonisolated struct SenderIdentity: Equatable {
    /// Shown for an app nobody has named. Deliberately not "Unknown": the sender is not
    /// unidentified — the app knows exactly what posted — it is unnamed, and saying
    /// "Unknown" describes a lookup that failed rather than one that cannot be made.
    static let unnamedApp = "App"
    /// Shown for a person the directory has not answered for: a deleted account, someone
    /// outside the directory, or a lookup still in flight.
    static let unnamedPerson = "Unknown"

    /// The sender's own name, or nil while all there is to show is a placeholder.
    let resolvedName: String?
    let photoURL: String?
    /// A Chat app or an incoming webhook. Chat reports the two identically, so this app
    /// cannot tell them apart either.
    let isApp: Bool

    init(resolvedName: String?, photoURL: String? = nil, isApp: Bool = false) {
        self.resolvedName = resolvedName
        self.photoURL = photoURL
        self.isApp = isApp
    }

    /// What to print where the sender is named.
    var name: String {
        resolvedName ?? (isApp ? Self.unnamedApp : Self.unnamedPerson)
    }
}

/// Main-actor, unlike the type itself: `CachedMessage` and `CachedUser` are SwiftData
/// models and so belong to the main actor under `SWIFT_DEFAULT_ACTOR_ISOLATION`, which is
/// where the views that hold them already are.
extension SenderIdentity {
    /// - Parameter sender: the sender's cached row, when one exists.
    @MainActor
    init(message: CachedMessage, sender: CachedUser?) {
        self.init(
            // The name on the message covers locally composed ones, which are shown
            // immediately — before there is a server copy, let alone a lookup.
            resolvedName: sender?.displayName ?? message.senderDisplayName,
            photoURL: sender?.photoURL,
            // Both sources are needed. The type is on messages cached since the app
            // started storing it, and on the sender's row for every *other* message they
            // posted — including history cached before then, which is most of it.
            isApp: sender?.isApp == true || message.isAppSender
        )
    }
}
