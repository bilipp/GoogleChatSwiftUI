import Foundation
import OSLog

/// Typed client over the Google Chat REST v1 surface.
///
/// A value type rather than an actor: it holds no mutable state, and all shared
/// mutation lives behind `TokenProvider`. That lets independent requests run
/// concurrently instead of queueing behind one another.
nonisolated struct ChatClient: Sendable {
    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "chat-api")

    private static let baseURL = URL(string: "https://chat.googleapis.com/v1/")!

    init(tokenProvider: TokenProvider, urlSession: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
    }

    // MARK: - Decoding

    /// Chat emits RFC 3339 timestamps, sometimes with fractional seconds and sometimes
    /// without. `.iso8601` handles only the latter, so both spellings are tried.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // `Date.ISO8601FormatStyle` is a Sendable value type; `ISO8601DateFormatter`
        // is a non-Sendable class and cannot be captured here safely.
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()

        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? withFraction.parse(raw) { return date }
            if let date = try? plain.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Bad RFC 3339 date: \(raw)")
            )
        }
        return decoder
    }()

    // MARK: - Requests

    func get<T: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: T.Type
    ) async throws -> T {
        var components = URLComponents(
            url: Self.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await execute(request, as: T.self)
    }

    func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body,
        as type: T.Type
    ) async throws -> T {
        try await mutate("POST", path: path, query: query, body: body, as: T.self)
    }

    /// Chat uses PATCH with an explicit `updateMask`; omitting the mask is rejected
    /// rather than treated as "update everything".
    func patch<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        updateMask: String,
        body: Body,
        as type: T.Type
    ) async throws -> T {
        try await mutate(
            "PATCH",
            path: path,
            query: [URLQueryItem(name: "updateMask", value: updateMask)],
            body: body,
            as: T.self
        )
    }

    func delete(_ path: String) async throws {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = "DELETE"
        _ = try await executeRaw(request)
    }

    private func mutate<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ method: String,
        path: String,
        query: [URLQueryItem],
        body: Body,
        as type: T.Type
    ) async throws -> T {
        var components = URLComponents(
            url: Self.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await execute(request, as: T.self)
    }

    private func execute<T: Decodable & Sendable>(
        _ request: URLRequest,
        as type: T.Type
    ) async throws -> T {
        let data = try await executeRaw(request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            logger.error("Decode failed for \(request.url?.path ?? "?"): \(error)")
            throw error
        }
    }

    /// Runs the request with auth, one 401 re-auth attempt, and bounded backoff.
    private func executeRaw(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        var didForceRefresh = false
        let maxAttempts = 4

        while true {
            attempt += 1

            var authorized = request
            let token = try await tokenProvider.validAccessToken()
            authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await urlSession.data(for: authorized)
            guard let http = response as? HTTPURLResponse else { throw AuthError.malformedResponse }

            if (200..<300).contains(http.statusCode) { return data }

            // A 401 means the server disagrees with our expiry bookkeeping. Force one
            // refresh and retry; a second 401 is a real authorization failure.
            if http.statusCode == 401, !didForceRefresh {
                didForceRefresh = true
                _ = try await tokenProvider.forceRefresh()
                continue
            }

            let apiError = ChatAPIError.decode(status: http.statusCode, from: data)
            guard apiError.isRetryable, attempt < maxAttempts else { throw apiError }

            let delay = Self.backoffDelay(attempt: attempt, response: http)
            logger.warning("Retrying after \(http.statusCode) in \(delay, format: .fixed(precision: 2))s")
            try await Task.sleep(for: .seconds(delay))
        }
    }

    /// Exponential backoff with jitter, deferring to `Retry-After` when Google sends it.
    /// Jitter matters here because Chat quotas are per-user-per-minute — synchronised
    /// retries from parallel requests would just re-collide.
    private static func backoffDelay(attempt: Int, response: HTTPURLResponse) -> Double {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header) {
            return seconds
        }
        let exponential = pow(2.0, Double(attempt - 1))
        return exponential + Double.random(in: 0...0.5)
    }
}

// MARK: - Endpoints

/// `nonisolated` for the same reason as the write endpoints: default main-actor
/// isolation would silently run response decoding — 762 spaces' worth — on the main
/// thread. Nothing errors, because `async` calls cross actors happily; it just hitches.
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
