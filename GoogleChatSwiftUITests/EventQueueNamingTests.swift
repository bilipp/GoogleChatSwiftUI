import Foundation
import Testing

@testable import GoogleChatSwiftUI

/// Deriving each person's Pub/Sub subscription from their address.
///
/// The bug these exist for: the subscription name was a constant, `chat-events-mac`.
/// That reads like a per-machine queue and behaves like nothing of the sort. Google
/// Chat publishes every subscriber's events into the one topic the Cloud project owns,
/// and a Pub/Sub subscription hands each message in its backlog to exactly one of the
/// clients pulling it. So a second colleague running the app did not get a second copy
/// of the stream — the two of them split it, at random, and each silently missed
/// roughly half their own messages. Manual refresh papered over it, which is why it
/// would present as flaky realtime rather than as a configuration mistake.
///
/// What the naming has to get right is two things at once: distinct per person, and
/// predictable enough that an administrator can create the queue from an address alone,
/// before that person has ever launched the app.
struct EventQueueNamingTests {
    @Test func theLocalPartOfTheAddressNamesTheQueue() {
        #expect(OAuthConfiguration.subscriptionID(for: "alice@innoloft.com") == "chat-events-alice")
    }

    /// The case that motivates all of this.
    @Test func twoColleaguesDoNotShareAQueue() {
        let mine = OAuthConfiguration.subscriptionID(for: "p.bischoff@innoloft.com")
        let theirs = OAuthConfiguration.subscriptionID(for: "alice@innoloft.com")
        #expect(mine != theirs)
    }

    /// Dots are legal in a Pub/Sub ID but are flattened anyway, so that the name can be
    /// derived by hand from an address without having to remember which punctuation
    /// survives. `gcloud` and the app have to agree on one spelling.
    @Test func punctuationInTheLocalPartBecomesDashes() {
        #expect(
            OAuthConfiguration.subscriptionID(for: "p.bischoff@innoloft.com")
                == "chat-events-p-bischoff"
        )
        #expect(
            OAuthConfiguration.subscriptionID(for: "anna+chat@innoloft.com")
                == "chat-events-anna-chat"
        )
    }

    /// Addresses are case-insensitive, Pub/Sub IDs are not — so a colleague typing a
    /// capital must not end up pointed at a second, non-existent queue.
    @Test func capitalisationDoesNotChangeTheQueue() {
        #expect(
            OAuthConfiguration.subscriptionID(for: "P.Bischoff@Innoloft.com")
                == OAuthConfiguration.subscriptionID(for: "p.bischoff@innoloft.com")
        )
    }

    /// Non-ASCII letters are not permitted in a Pub/Sub ID, so they cannot be passed
    /// through even though they are perfectly good in an address.
    @Test func nonASCIILettersAreReducedToDashes() {
        #expect(OAuthConfiguration.subscriptionID(for: "jörg@innoloft.com") == "chat-events-j-rg")
    }

    /// A bare local part with no `@` is still something to name a queue after rather
    /// than a reason to return the prefix alone, which every such address would share.
    @Test func anAddressWithNoDomainStillNamesItsOwnQueue() {
        #expect(OAuthConfiguration.subscriptionID(for: "alice") == "chat-events-alice")
    }

    @Test func theFullNameIsProjectScoped() {
        let name = OAuthConfiguration.pubSubSubscription(for: "alice@innoloft.com")
        #expect(name.hasPrefix("projects/"))
        #expect(name.hasSuffix("/subscriptions/chat-events-alice"))
    }
}
