import Foundation
import OSLog

/// Shared authenticated JSON transport for every Google API this app talks to:
/// Chat, Workspace Events, and Pub/Sub.
///
/// Auth injection, the 401 re-auth dance, and jittered backoff are identical across
/// all three, so they live here once rather than being reimplemented per client.
nonisolated struct GoogleTransport: Sendable {
    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let logger = AppLog.logger("transport")

    init(tokenProvider: TokenProvider, urlSession: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
    }

    /// Google emits RFC 3339 timestamps, sometimes with fractional seconds and
    /// sometimes without. `.iso8601` handles only the latter, so both are tried.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Value types: `ISO8601DateFormatter` is a non-Sendable class and cannot be
        // captured in the `@Sendable` decoding closure.
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

    func decode<T: Decodable & Sendable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await data(for: request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            logger.error("Decode failed for \(request.url?.path ?? "?"): \(error)")
            throw error
        }
    }

    /// Runs the request with auth, one forced token refresh on 401, and bounded
    /// jittered backoff on retryable failures.
    @discardableResult
    func data(for request: URLRequest) async throws -> Data {
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
            try await Task.sleep(for: .seconds(delay))
        }
    }

    /// Jitter matters because Google quotas are per-user-per-minute: synchronised
    /// retries from parallel requests would just re-collide at the same instant.
    private static func backoffDelay(attempt: Int, response: HTTPURLResponse) -> Double {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header) {
            return seconds
        }
        return pow(2.0, Double(attempt - 1)) + Double.random(in: 0...0.5)
    }

    // MARK: - Convenience

    func get<T: Decodable & Sendable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await decode(request, as: T.self)
    }

    func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        as type: T.Type
    ) async throws -> T {
        try await mutate("POST", url: url, body: body, as: T.self)
    }

    func patch<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        as type: T.Type
    ) async throws -> T {
        try await mutate("PATCH", url: url, body: body, as: T.self)
    }

    func mutate<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ method: String,
        url: URL,
        body: Body,
        as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await decode(request, as: T.self)
    }

    func delete(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        try await data(for: request)
    }
}
