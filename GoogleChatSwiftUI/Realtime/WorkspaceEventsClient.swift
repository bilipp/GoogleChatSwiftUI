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

// MARK: - Client

/// Manages the Google Workspace Events subscription that feeds Chat events into
/// our Pub/Sub topic.
nonisolated struct WorkspaceEventsClient: Sendable {
    private let transport: GoogleTransport
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "events")

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

    func createSubscription() async throws -> EventSubscription {
        let body = CreateSubscriptionBody(
            targetResource: Self.targetResource,
            eventTypes: Self.eventTypes,
            notificationEndpoint: .init(pubsubTopic: OAuthConfiguration.pubSubTopic),
            // Without the resource inline, every event would cost an extra Chat API
            // round-trip just to learn what changed.
            payloadOptions: .init(includeResource: true)
        )
        let created = try await transport.post(
            Self.baseURL.appending(path: "subscriptions"),
            body: body,
            as: EventSubscription.self
        )
        logger.info("Created subscription \(created.name ?? "?")")
        return created
    }

    /// Extends a subscription to its maximum expiry.
    func renew(_ name: String) async throws -> EventSubscription {
        var components = URLComponents(
            url: Self.baseURL.appending(path: name),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "updateMask", value: "ttl")]
        let renewed = try await transport.patch(
            components.url!,
            body: RenewSubscriptionBody(ttl: "0s"),
            as: EventSubscription.self
        )
        logger.info("Renewed \(name) until \(renewed.expireTime?.description ?? "?")")
        return renewed
    }

    func delete(_ name: String) async throws {
        try await transport.delete(Self.baseURL.appending(path: name))
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
