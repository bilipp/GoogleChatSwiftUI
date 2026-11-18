import Foundation

/// A message pinned to the top of a space, shared with everyone in it.
nonisolated struct ChatMessagePin: Decodable, Sendable, Hashable {
    /// `spaces/{space}/messagePins/{pin}`. The pin's ID is the pinned message's ID.
    let name: String?
    /// The pinned message's resource name, `spaces/{space}/messages/{message}`.
    let message: String?
}

nonisolated struct ListMessagePinsResponse: Decodable, Sendable {
    let messagePins: [ChatMessagePin]?
    let nextPageToken: String?
}

private nonisolated struct CreateMessagePinBody: Encodable, Sendable {
    let message: String
}

nonisolated extension ChatClient {
    /// The messages pinned in a space, as message resource names, in the order Chat
    /// lists them.
    func pinnedMessageNames(in space: String) async throws -> [String] {
        var collected: [String] = []
        var token: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page = try await get("\(space)/messagePins", query: query, as: ListMessagePinsResponse.self)
            collected.append(contentsOf: (page.messagePins ?? []).compactMap(\.message))
            token = page.nextPageToken
        } while !(token ?? "").isEmpty
        return collected
    }

    /// Pins a message for everyone in its space.
    /// - Parameter messageName: `spaces/{space}/messages/{message}`.
    func pinMessage(name messageName: String) async throws {
        guard let space = ChatEvent.space(fromMessageName: messageName) else { return }
        _ = try await post(
            "\(space)/messagePins",
            body: CreateMessagePinBody(message: messageName),
            as: ChatMessagePin.self
        )
    }

    /// Removes a pin. The pin is addressed by the message's own ID.
    func unpinMessage(name messageName: String) async throws {
        guard let space = ChatEvent.space(fromMessageName: messageName),
              let messageID = messageName.split(separator: "/").last
        else { return }
        try await delete("\(space)/messagePins/\(messageID)")
    }
}
