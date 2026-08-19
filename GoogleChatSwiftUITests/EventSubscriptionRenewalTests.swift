import Foundation
import Testing

@testable import GoogleChatSwiftUI

/// Renewing the Workspace Events subscription that realtime delivery depends on.
///
/// The bug these exist for: `subscriptions.create` and `subscriptions.patch` do not
/// answer with a `Subscription`. They answer with a long-running `Operation` that
/// wraps one, and an `Operation` carries its *own* name — `operations/…`. Because
/// every field of `EventSubscription` is optional, decoding the operation body as a
/// subscription succeeded rather than failed, and handed back a subscription whose
/// name was the operation's.
///
/// From there the app renewed the wrong resource. The 30-minute renewal PATCHed
/// `/v1/operations/…`, which fails every single time, and the catch that was supposed
/// to recover re-derived the same operation name and failed again on the next pass.
/// So the subscription was renewed exactly once per launch, then quietly ran out its
/// TTL — after which Chat published nothing and the sidebar stopped moving. Opening a
/// conversation still worked, because that path re-fetches from the Chat API instead
/// of waiting for an event, which is what made it look like a rendering problem
/// rather than a dead subscription.
struct EventSubscriptionRenewalTests {
    /// The decode that started it: an operation body is *valid* as a subscription.
    ///
    /// This is pinned rather than fixed, because it cannot be fixed at this layer —
    /// the two shapes really do overlap. It is the reason create and patch must be
    /// decoded as operations and unwrapped, and the reason the unwrapping checks the
    /// name it gets rather than trusting that a response is present.
    @Test func anOperationBodyDecodesAsASubscriptionAndCarriesTheWrongName() throws {
        let operationBody = Data(#"""
        {
          "name": "operations/abc123",
          "done": true,
          "response": {
            "@type": "type.googleapis.com/google.apps.events.subscriptions.v1.Subscription",
            "name": "subscriptions/real456",
            "targetResource": "//chat.googleapis.com/spaces/-",
            "state": "ACTIVE",
            "expireTime": "2026-08-19T18:00:00Z"
          }
        }
        """#.utf8)

        let misread = try GoogleTransport.decoder.decode(EventSubscription.self, from: operationBody)

        // No error thrown, and every meaningful field is gone.
        #expect(misread.name == "operations/abc123")
        #expect(misread.targetResource == nil)
        #expect(misread.expireTime == nil)
        // Which also means the reuse check in `ensureSubscription` would reject it.
        #expect(misread.isActive == false)
    }

    /// The guard that stops the confusion from reaching Google as a 404.
    ///
    /// Without it the request is well-formed and the API answers "not found", which
    /// reads as an expired subscription and sends you looking in the wrong place.
    @Test func renewingAnOperationNameIsRefusedBeforeItLeaves() async throws {
        let client = WorkspaceEventsClient(
            transport: GoogleTransport(tokenProvider: TokenProvider())
        )

        await #expect(throws: WorkspaceEventsError.self) {
            _ = try await client.renew("operations/abc123")
        }
    }

    /// A real subscription name gets past the guard.
    ///
    /// It fails afterwards, on there being no signed-in session — which is the point:
    /// the refusal above is about the name, not about the client being unusable.
    @Test func renewingASubscriptionNameGetsAsFarAsAuthentication() async throws {
        let client = WorkspaceEventsClient(
            transport: GoogleTransport(tokenProvider: TokenProvider())
        )

        await #expect(throws: AuthError.self) {
            _ = try await client.renew("subscriptions/real456")
        }
    }

    @Test func subscriptionNamesAreTheOnesTheAPIDocuments() {
        #expect("subscriptions/real456".hasPrefix(WorkspaceEventsClient.namePrefix))
        #expect(!"operations/abc123".hasPrefix(WorkspaceEventsClient.namePrefix))
    }
}
