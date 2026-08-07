import Foundation
import OSLog

/// Typed client over the Google Chat REST v1 surface.
///
/// A value type rather than an actor: it holds no mutable state, and all shared
/// mutation lives behind `TokenProvider`. That lets independent requests run
/// concurrently instead of queueing behind one another.
nonisolated struct ChatClient: Sendable {
    let transport: GoogleTransport

    private static let baseURL = URL(string: "https://chat.googleapis.com/v1/")!

    init(tokenProvider: TokenProvider, urlSession: URLSession = .shared) {
        transport = GoogleTransport(tokenProvider: tokenProvider, urlSession: urlSession)
    }

    private func url(_ path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(
            url: Self.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    func get<T: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: T.Type
    ) async throws -> T {
        try await transport.get(url(path, query: query), as: T.self)
    }

    func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body,
        as type: T.Type
    ) async throws -> T {
        try await transport.post(url(path, query: query), body: body, as: T.self)
    }

    /// Chat uses PATCH with an explicit `updateMask`; omitting the mask is rejected
    /// rather than treated as "update everything".
    func patch<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        updateMask: String,
        body: Body,
        as type: T.Type
    ) async throws -> T {
        let target = url(path, query: [URLQueryItem(name: "updateMask", value: updateMask)])
        return try await transport.patch(target, body: body, as: T.self)
    }

    func delete(_ path: String) async throws {
        try await transport.delete(url(path, query: []))
    }
}

// MARK: - Endpoints

/// `nonisolated` is load-bearing: with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// an unannotated extension is inferred main-actor, which would silently run response
/// decoding — 762 spaces' worth — on the main thread. Nothing errors, because `async`
/// calls cross actors happily; it just hitches.
nonisolated extension ChatClient {
    /// Spaces the signed-in user belongs to.
    ///
    /// User auth scopes this to the caller's own memberships — there is no way to
    /// enumerate the whole org without admin privileges.
    func listSpaces(pageSize: Int = 100, pageToken: String? = nil) async throws -> ListSpacesResponse {
        var query = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await get("spaces", query: query, as: ListSpacesResponse.self)
    }

    /// All spaces, following pagination to exhaustion.
    func allSpaces() async throws -> [ChatSpace] {
        var collected: [ChatSpace] = []
        var token: String?
        repeat {
            let page = try await listSpaces(pageToken: token)
            collected.append(contentsOf: page.spaces ?? [])
            token = page.nextPageToken
        } while token != nil && !token!.isEmpty
        return collected
    }

    /// Members of a space.
    ///
    /// This is the only way to name a DM: `spaces.list` returns no `displayName` for
    /// direct messages or unnamed group chats, so the peer's name has to come from
    /// their membership.
    func listMembers(
        in space: String,
        pageSize: Int = 20,
        pageToken: String? = nil
    ) async throws -> ListMembersResponse {
        var query = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await get("\(space)/members", query: query, as: ListMembersResponse.self)
    }

    /// Every member of a space, following pagination.
    ///
    /// Separate from `listMembers` because the two want different things. Naming a DM
    /// needs the first handful and no more, so it pays for one call; offering someone
    /// to mention has to cover the room, or the colleague you were reaching for is
    /// simply missing with no sign that anything was left out.
    ///
    /// - Parameter limit: a ceiling on how far to page. Chat spaces can hold thousands
    ///   of people, and a list that long is not something anyone scrolls — past this
    ///   the completion is doing more harm than the extra names are worth.
    func allMembers(in space: String, limit: Int = 500) async throws -> [ChatMembership] {
        var collected: [ChatMembership] = []
        var token: String?
        repeat {
            let page = try await listMembers(in: space, pageSize: 100, pageToken: token)
            collected.append(contentsOf: page.memberships ?? [])
            token = page.nextPageToken
        } while !(token ?? "").isEmpty && collected.count < limit
        return collected
    }

    /// Messages in a space, newest first.
    /// - Parameter space: resource name, e.g. `spaces/AAAA1111`.
    func listMessages(
        in space: String,
        pageSize: Int = 50,
        pageToken: String? = nil
    ) async throws -> ListMessagesResponse {
        var query = [
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "orderBy", value: "createTime desc"),
            // Without this, deleted messages vanish and leave confusing gaps in threads.
            URLQueryItem(name: "showDeleted", value: "true"),
        ]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await get("\(space)/messages", query: query, as: ListMessagesResponse.self)
    }
}
