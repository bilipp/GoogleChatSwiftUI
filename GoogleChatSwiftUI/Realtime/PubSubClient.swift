import Foundation
import OSLog

// MARK: - Wire models

nonisolated struct PubSubReceivedMessage: Decodable, Sendable {
    let ackId: String?
    let message: PubSubMessage?
}

nonisolated struct PubSubMessage: Decodable, Sendable {
    let messageId: String?
    /// Base64-encoded payload.
    let data: String?
    /// CloudEvents metadata; `ce-type` carries the Chat event type.
    let attributes: [String: String]?
    let publishTime: Date?

    var decodedData: Data? {
        guard let data else { return nil }
        return Data(base64Encoded: data)
    }

    var eventType: String? {
        attributes?["ce-type"]
    }
}

nonisolated struct PullResponse: Decodable, Sendable {
    let receivedMessages: [PubSubReceivedMessage]?
}

private nonisolated struct PullRequest: Encodable, Sendable {
    let maxMessages: Int
}

private nonisolated struct AcknowledgeRequest: Encodable, Sendable {
    let ackIds: [String]
}

// MARK: - Client

/// Pulls Chat events straight from Cloud Pub/Sub using the signed-in user's own
/// credentials.
///
/// This is what removes the need for a backend. Push delivery would require a
/// publicly reachable HTTPS endpoint; pull works fine from a desktop app, and the
/// user holds `roles/pubsub.subscriber` on the subscription directly.
nonisolated struct PubSubClient: Sendable {
    private let transport: GoogleTransport
    private let logger = AppLog.logger("pubsub")

    private static let baseURL = URL(string: "https://pubsub.googleapis.com/v1/")!

    init(transport: GoogleTransport) {
        self.transport = transport
    }

    func pull(maxMessages: Int = 100) async throws -> [PubSubReceivedMessage] {
        let url = Self.baseURL.appending(path: "\(OAuthConfiguration.pubSubSubscription):pull")
        let response = try await transport.post(
            url,
            body: PullRequest(maxMessages: maxMessages),
            as: PullResponse.self
        )
        return response.receivedMessages ?? []
    }

    /// Acknowledges messages so Pub/Sub stops redelivering them.
    ///
    /// Only called after events are durably applied to the store: acking first would
    /// silently drop events if the app crashed mid-write.
    func acknowledge(ackIds: [String]) async throws {
        guard !ackIds.isEmpty else { return }
        let url = Self.baseURL.appending(path: "\(OAuthConfiguration.pubSubSubscription):acknowledge")
        // Ack returns an empty JSON object.
        _ = try await transport.post(url, body: AcknowledgeRequest(ackIds: ackIds), as: EmptyResponse.self)
    }
}

nonisolated struct EmptyResponse: Decodable, Sendable {}
