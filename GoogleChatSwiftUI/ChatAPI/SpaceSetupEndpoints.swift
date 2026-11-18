import Foundation

/// The `spaces.setup` request for a named space or a group chat.
///
/// `setup` rather than `create` for the same reason as the DM body: it is the one call
/// that creates the conversation *and* puts people in it. The caller is added by Chat
/// and must not be listed.
private nonisolated struct SetUpSpaceBody: Encodable, Sendable {
    struct SpaceRef: Encodable, Sendable {
        struct Details: Encodable, Sendable { let description: String }
        let spaceType: String
        /// Required for a named space, refused for a group chat.
        let displayName: String?
        let spaceDetails: Details?
    }

    let space: SpaceRef
    /// Makes a retried request return the space the first attempt created rather than
    /// a second one.
    let requestId: String
    let memberships: [SetUpDirectMessageBody.MembershipRef]
}

private nonisolated struct FindGroupChatsResponse: Decodable, Sendable {
    let spaces: [ChatSpace]?
}

nonisolated extension ChatClient {
    /// Chat accepts at most this many people besides the caller in one `setup` call.
    static let maxInitialMembers = 49

    /// Creates a named space with the given people in it.
    ///
    /// - Parameter members: Chat user resource names, `users/{id}` or `users/{email}`.
    ///   People the caller is not allowed to add are skipped by Chat without an error.
    /// - Throws: `ChatAPIError` with status 409 when a space with that name exists.
    func setUpSpace(
        displayName: String,
        description: String?,
        members: [String]
    ) async throws -> ChatSpace {
        try await post(
            "spaces:setup",
            body: SetUpSpaceBody(
                space: .init(
                    spaceType: "SPACE",
                    displayName: displayName,
                    spaceDetails: description.map { .init(description: $0) }
                ),
                requestId: UUID().uuidString,
                memberships: Self.memberships(members)
            ),
            as: ChatSpace.self
        )
    }

    /// Creates an unnamed group chat. Chat needs at least two people besides the caller;
    /// with one it would be a DM, which has its own call.
    func setUpGroupChat(members: [String]) async throws -> ChatSpace {
        try await post(
            "spaces:setup",
            body: SetUpSpaceBody(
                space: .init(spaceType: "GROUP_CHAT", displayName: nil, spaceDetails: nil),
                requestId: UUID().uuidString,
                memberships: Self.memberships(members)
            ),
            as: ChatSpace.self
        )
    }

    /// Group chats whose people are exactly the caller plus `users`, so starting one
    /// with the same people reopens it instead of creating a duplicate.
    func findGroupChats(with users: [String]) async throws -> [ChatSpace] {
        var query = users.map { URLQueryItem(name: "users", value: $0) }
        query.append(URLQueryItem(name: "spaceView", value: "SPACE_VIEW_EXPANDED"))
        query.append(URLQueryItem(name: "pageSize", value: "30"))
        return try await get(
            "spaces:findGroupChats",
            query: query,
            as: FindGroupChatsResponse.self
        ).spaces ?? []
    }

    private static func memberships(_ users: [String]) -> [SetUpDirectMessageBody.MembershipRef] {
        users.prefix(maxInitialMembers).map { .init(member: .init(name: $0)) }
    }
}
