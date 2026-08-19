import Foundation
import OSLog

// MARK: - Wire models

nonisolated struct EventSubscription: Decodable, Sendable {
    /// Resource name, e.g. `subscriptions/abc123`.
    let name: String?
    let targetResource: String?
    let eventTypes: [String]?
    let state: String?
    let expireTime: Date?
    let suspensionReason: String?

    var isActive: Bool { state == "ACTIVE" }
}

nonisolated struct ListSubscriptionsResponse: Decodable, Sendable {
    let subscriptions: [EventSubscription]?
    let nextPageToken: String?
}

/// The long-running-operation envelope that `create`, `patch` and `delete` return.
///
/// Those three do not answer with a `Subscription` — they answer with an `Operation`
/// wrapping one. This type has to exist rather than being decoded away, because the
/// two shapes overlap: every field of `EventSubscription` is optional, so decoding a
/// `Subscription` straight out of an operation body *succeeds* and quietly yields
/// `name` = `operations/…` with a nil state and expiry. A renewal aimed at that path
/// then fails on every attempt, and the subscription it was supposed to extend runs
/// out its clock and stops delivering.
private nonisolated struct SubscriptionOperation: Decodable, Sendable {
    nonisolated struct Failure: Decodable, Sendable {
        let code: Int?
        let message: String?
    }

    let name: String?
    let done: Bool?
    /// Present once `done` is true and the operation succeeded.
    let response: EventSubscription?
    let error: Failure?
}

private nonisolated struct CreateSubscriptionBody: Encodable, Sendable {
    nonisolated struct NotificationEndpoint: Encodable, Sendable { let pubsubTopic: String }
    nonisolated struct PayloadOptions: Encodable, Sendable { let includeResource: Bool }

    let targetResource: String
    let eventTypes: [String]
    let notificationEndpoint: NotificationEndpoint
    let payloadOptions: PayloadOptions
}

private nonisolated struct RenewSubscriptionBody: Encodable, Sendable {
    /// `"0s"` means "extend to the maximum allowed", which keeps this renewal logic
    /// independent of whatever the current maximum TTL happens to be — Google's docs
    /// are vague on the exact value and it differs with `includeResource`.
    let ttl: String
}

// MARK: - Errors

nonisolated enum WorkspaceEventsError: LocalizedError, Sendable {
    /// A renewal was handed something other than a subscription resource name.
    ///
    /// Worth failing loudly on: the API accepts the request and reports a plain 404,
    /// which reads as "the subscription is gone" rather than "we asked about the wrong
    /// kind of thing".
    case notASubscriptionName(String)
    case operationCarriedNoSubscription(String?)

    var errorDescription: String? {
        switch self {
        case .notASubscriptionName(let name):
            "Expected a subscriptions/… resource name, but got '\(name)'."
        case .operationCarriedNoSubscription(let operation):
            "Operation \(operation ?? "?") finished without naming a subscription."
        }
    }
}

// MARK: - Client

/// Manages the Google Workspace Events subscription that feeds Chat events into
/// our Pub/Sub topic.
nonisolated struct WorkspaceEventsClient: Sendable {
    private let transport: GoogleTransport
    private let logger = AppLog.logger("events")

    private static let baseURL = URL(string: "https://workspaceevents.googleapis.com/v1/")!

    /// All spaces the signed-in user belongs to — one subscription rather than 762.
    static let targetResource = "//chat.googleapis.com/spaces/-"

    static let eventTypes = [
        "google.workspace.chat.message.v1.created",
        "google.workspace.chat.message.v1.updated",
        "google.workspace.chat.message.v1.deleted",
        "google.workspace.chat.reaction.v1.created",
        "google.workspace.chat.reaction.v1.deleted",
        "google.workspace.chat.membership.v1.created",
        "google.workspace.chat.membership.v1.updated",
        "google.workspace.chat.membership.v1.deleted",
        "google.workspace.chat.space.v1.updated",
    ]

    /// Prefix of every subscription resource name, and the one thing that
    /// distinguishes one from the operation that acted on it.
    static let namePrefix = "subscriptions/"

    init(transport: GoogleTransport) {
        self.transport = transport
    }

    func listSubscriptions() async throws -> [EventSubscription] {
        var components = URLComponents(
            url: Self.baseURL.appending(path: "subscriptions"),
            resolvingAgainstBaseURL: false
        )!
        // The API requires a filter; an unfiltered list is rejected.
        components.queryItems = [
            URLQueryItem(name: "filter", value: "event_types:\"\(Self.eventTypes[0])\"")
        ]
        let response = try await transport.get(components.url!, as: ListSubscriptionsResponse.self)
        return response.subscriptions ?? []
    }

    /// Reads one subscription back. Unlike create and renew, this really does answer
    /// with a `Subscription`.
    func subscription(named name: String) async throws -> EventSubscription {
        try await transport.get(Self.baseURL.appending(path: name), as: EventSubscription.self)
    }

    func createSubscription() async throws -> EventSubscription {
        let body = CreateSubscriptionBody(
            targetResource: Self.targetResource,
            eventTypes: Self.eventTypes,
            notificationEndpoint: .init(pubsubTopic: OAuthConfiguration.pubSubTopic),
            // Without the resource inline, every event would cost an extra Chat API
            // round-trip just to learn what changed.
            payloadOptions: .init(includeResource: true)
        )
        let operation = try await transport.post(
            Self.baseURL.appending(path: "subscriptions"),
            body: body,
            as: SubscriptionOperation.self
        )
        let created = try await subscription(fromOperation: operation)
        logger.info("Created subscription \(created.name ?? "?")")
        return created
    }

    /// Extends a subscription to its maximum expiry.
    ///
    /// - Parameter name: A `subscriptions/…` name. Passing the name of the operation
    ///   that last touched the subscription is the mistake this guards against.
    func renew(_ name: String) async throws -> EventSubscription {
        guard name.hasPrefix(Self.namePrefix) else {
            throw WorkspaceEventsError.notASubscriptionName(name)
        }

        var components = URLComponents(
            url: Self.baseURL.appending(path: name),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "updateMask", value: "ttl")]
        let operation = try await transport.patch(
            components.url!,
            body: RenewSubscriptionBody(ttl: "0s"),
            as: SubscriptionOperation.self
        )
        let renewed = try await subscription(fromOperation: operation, fallingBackTo: name)
        logger.info("Renewed \(name) until \(renewed.expireTime?.description ?? "?")")
        return renewed
    }

    func delete(_ name: String) async throws {
        try await transport.delete(Self.baseURL.appending(path: name))
    }

    /// Pulls the subscription out of the operation that produced it.
    ///
    /// - Parameter fallbackName: A subscription already known to the caller, read back
    ///   directly when the operation is still running and so carries no resource yet.
    ///   A create has no such name, and there the list is the only route to it.
    private func subscription(
        fromOperation operation: SubscriptionOperation,
        fallingBackTo fallbackName: String? = nil
    ) async throws -> EventSubscription {
        if let failure = operation.error {
            throw ChatAPIError(
                status: failure.code ?? 0,
                googleStatus: nil,
                message: failure.message
            )
        }

        // The name is checked, not just the presence of a response: it is the field
        // everything downstream renews against.
        if let response = operation.response,
           let name = response.name,
           name.hasPrefix(Self.namePrefix) {
            return response
        }

        if let fallbackName {
            return try await subscription(named: fallbackName)
        }

        guard let created = try await listSubscriptions().first(where: {
            $0.targetResource == Self.targetResource
        }) else {
            throw WorkspaceEventsError.operationCarriedNoSubscription(operation.name)
        }
        return created
    }

    /// Finds a reusable subscription or creates one.
    ///
    /// Subscriptions outlive the app process, so recreating blindly on every launch
    /// would leak them until the per-user cap is hit.
    func ensureSubscription() async throws -> EventSubscription {
        let existing = try await listSubscriptions()

        if let reusable = existing.first(where: {
            $0.isActive && $0.targetResource == Self.targetResource
        }) {
            logger.info("Reusing subscription \(reusable.name ?? "?")")
            // Renew on adoption: it may be close to expiry after the app was closed.
            // The listed row is what gets returned if that fails, because it is the
            // one that is certain to carry a usable resource name.
            if let name = reusable.name {
                return (try? await renew(name)) ?? reusable
            }
            return reusable
        }

        // A suspended subscription cannot be revived by patching; it has to go.
        for stale in existing where !stale.isActive {
            if let name = stale.name {
                logger.info("Deleting \(stale.state ?? "inactive") subscription \(name)")
                try? await delete(name)
            }
        }

        return try await createSubscription()
    }
}
