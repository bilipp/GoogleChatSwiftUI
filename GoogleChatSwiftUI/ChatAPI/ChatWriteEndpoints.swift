import Foundation

// Request bodies for the mutating Chat endpoints.

nonisolated struct CreateMessageBody: Encodable, Sendable {
    var text: String
    var thread: ThreadRef?

    nonisolated struct ThreadRef: Encodable, Sendable {
        var name: String
    }
}

nonisolated struct UpdateMessageBody: Encodable, Sendable {
    var text: String
}

nonisolated struct SpaceReadStateBody: Encodable, Sendable {
    var lastReadTime: String
}

/// `nonisolated` is load-bearing: with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// an unannotated extension is inferred main-actor, which both breaks synchronous
/// calls from `SyncEngine` and would drag every network round-trip onto the main
/// thread.
nonisolated extension ChatClient {
    /// Sends a message.
    ///
    /// - Parameter clientMessageID: idempotency key. The transport retries on 429/5xx,
    ///   and without a client-assigned ID a retry whose original actually succeeded
    ///   would post the message twice. Chat rejects the duplicate with ALREADY_EXISTS
    ///   instead, which we resolve by fetching the message that did land.
    func createMessage(
        in space: String,
        text: String,
        threadName: String? = nil,
        clientMessageID: String = ChatClient.newClientMessageID()
    ) async throws -> ChatMessage {
        var query = [URLQueryItem(name: "messageId", value: clientMessageID)]
        if threadName != nil {
            // Fall back to starting a thread if the target thread has gone away,
            // rather than failing the send outright.
            query.append(URLQueryItem(
                name: "messageReplyOption",
                value: "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD"
            ))
        }

        let body = CreateMessageBody(
            text: text,
            thread: threadName.map { CreateMessageBody.ThreadRef(name: $0) }
        )

        do {
            return try await post("\(space)/messages", query: query, body: body, as: ChatMessage.self)
        } catch let error as ChatAPIError where error.googleStatus == "ALREADY_EXISTS" {
            // A retry raced its own original. The message exists; go read it.
            return try await getMessage(name: "\(space)/messages/\(clientMessageID)")
        }
    }

    func getMessage(name: String) async throws -> ChatMessage {
        try await get(name, as: ChatMessage.self)
    }

    /// Edits a message's text. Only the sender may edit their own messages.
    func updateMessage(name: String, text: String) async throws -> ChatMessage {
        try await patch(
            name,
            updateMask: "text",
            body: UpdateMessageBody(text: text),
            as: ChatMessage.self
        )
    }

    func deleteMessage(name: String) async throws {
        try await delete(name)
    }

    /// Marks a space read up to `time`.
    ///
    /// The read-state resource is per-caller: you can set your own and no one else's,
    /// and there is no way to observe whether anyone has read yours.
    func markSpaceRead(spaceName: String, upTo time: Date = Date()) async throws {
        let spaceID = spaceName.replacingOccurrences(of: "spaces/", with: "")
        let path = "users/me/spaces/\(spaceID)/spaceReadState"
        let stamp = time.formatted(.iso8601)
        _ = try await patch(
            path,
            updateMask: "lastReadTime",
            body: SpaceReadStateBody(lastReadTime: stamp),
            as: SpaceReadStateResponse.self
        )
    }

    /// Chat requires client-assigned IDs to start with `client-` and contain only
    /// lowercase letters, numbers, and hyphens, up to 63 characters.
    static func newClientMessageID() -> String {
        "client-" + UUID().uuidString.lowercased()
    }
}

nonisolated struct SpaceReadStateResponse: Decodable, Sendable {
    let name: String?
    let lastReadTime: Date?
}
