import Foundation

// Request bodies for the mutating Chat endpoints.

nonisolated struct CreateMessageBody: Encodable, Sendable {
    var text: String
    var thread: ThreadRef?
    /// Uploaded files, referenced by the token `media.upload` returned.
    var attachment: [AttachmentRef]?

    nonisolated struct ThreadRef: Encodable, Sendable {
        var name: String
    }

    nonisolated struct AttachmentRef: Encodable, Sendable {
        var attachmentDataRef: ChatAttachment.DataRef
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
        attachments: [ChatAttachment.DataRef] = [],
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
            thread: threadName.map { CreateMessageBody.ThreadRef(name: $0) },
            attachment: attachments.isEmpty
                ? nil
                : attachments.map { CreateMessageBody.AttachmentRef(attachmentDataRef: $0) }
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

    /// The signed-in user's read position in a space.
    ///
    /// Read state is per-caller: you can read and set your own and no one else's,
    /// which is also why there are no read receipts anywhere in this app.
    func spaceReadState(spaceName: String) async throws -> SpaceReadStateResponse {
        let spaceID = spaceName.replacingOccurrences(of: "spaces/", with: "")
        return try await get("users/me/spaces/\(spaceID)/spaceReadState", as: SpaceReadStateResponse.self)
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

    // MARK: - Reactions

    func createReaction(messageName: String, unicode: String) async throws -> ChatReaction {
        try await post(
            "\(messageName)/reactions",
            body: CreateReactionBody(emoji: .init(unicode: unicode, customEmoji: nil)),
            as: ChatReaction.self
        )
    }

    func deleteReaction(name: String) async throws {
        try await delete(name)
    }

    /// Everyone's reactions to a message.
    ///
    /// `Message.emojiReactionSummaries` gives counts but never says whether *you*
    /// reacted, and there is no field that does — so toggling requires this call to
    /// find your own reaction's resource name.
    func listReactions(messageName: String) async throws -> ListReactionsResponse {
        try await get(
            "\(messageName)/reactions",
            query: [URLQueryItem(name: "pageSize", value: "200")],
            as: ListReactionsResponse.self
        )
    }

    // MARK: - Media

    /// Downloads an attachment's bytes.
    ///
    /// Always via `media.download` with the data ref, never via `downloadUri` or
    /// `thumbnailUri`. Those two are documented as links for a *human* in a browser;
    /// apps are explicitly told not to fetch them, and they are not plain public URLs.
    /// - Parameter resourceName: from `attachmentDataRef.resourceName`.
    func downloadAttachment(resourceName: String) async throws -> Data {
        var components = URLComponents(
            string: "https://chat.googleapis.com/v1/media/\(resourceName)"
        )!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await transport.data(for: request)
    }

    /// Uploads a file and returns the reference needed to attach it to a message.
    ///
    /// Upload is a two-step dance: bytes go to the `/upload/` host first, and the
    /// token that comes back is then attached to a normal message create. A message
    /// cannot carry raw bytes directly.
    func uploadAttachment(
        to space: String,
        filename: String,
        mimeType: String,
        data: Data
    ) async throws -> ChatAttachment.DataRef {
        var components = URLComponents(
            string: "https://chat.googleapis.com/upload/v1/\(space)/attachments:upload"
        )!
        components.queryItems = [URLQueryItem(name: "uploadType", value: "multipart")]

        // Hand-built multipart: the metadata part must be JSON and the media part raw
        // bytes, in that order, which URLSession offers no builder for.
        let boundary = "chatswiftui-\(UUID().uuidString)"
        var body = Data()

        let metadata = try JSONEncoder().encode(UploadMetadata(filename: filename))
        body.append("--\(boundary)\r\n")
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadata)
        body.append("\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/related; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let response = try await transport.decode(request, as: UploadAttachmentResponse.self)
        guard let ref = response.attachmentDataRef else {
            throw ChatAPIError(
                status: 200,
                googleStatus: "MALFORMED_RESPONSE",
                message: "Upload succeeded but returned no attachment reference."
            )
        }
        return ref
    }
}

private nonisolated struct UploadMetadata: Encodable, Sendable {
    let filename: String
}

nonisolated struct UploadAttachmentResponse: Decodable, Sendable {
    let attachmentDataRef: ChatAttachment.DataRef?
}

/// `nonisolated` for the usual reason under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`:
/// an unannotated extension is inferred main-actor, and this is called from the
/// nonisolated upload path.
private nonisolated extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

private nonisolated struct CreateReactionBody: Encodable, Sendable {
    let emoji: ChatEmoji
}

nonisolated struct SpaceReadStateResponse: Decodable, Sendable {
    let name: String?
    let lastReadTime: Date?
}
