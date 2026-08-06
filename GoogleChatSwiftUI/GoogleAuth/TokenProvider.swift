import Foundation
import OSLog

/// Owns the token lifecycle: persistence, expiry checking, and refresh.
///
/// Every authenticated API call in the app funnels through `validAccessToken()`.
/// Concurrent callers that arrive while a refresh is in flight all await the *same*
/// refresh task rather than each firing their own — Google invalidates the previous
/// access token on refresh, so overlapping refreshes race each other into failure.
actor TokenProvider {
    private let storage: KeychainTokenStorage
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "auth")

    private var tokens: OAuthTokens?
    private var refreshTask: Task<OAuthTokens, Error>?

    init(storage: KeychainTokenStorage = KeychainTokenStorage(), urlSession: URLSession = .shared) {
        self.storage = storage
        self.urlSession = urlSession
    }

    /// Restores persisted tokens. Returns whether a usable session was found.
    func restore() -> Bool {
        do {
            tokens = try storage.load()
        } catch {
            logger.error("Failed to read tokens from keychain: \(error.localizedDescription)")
            tokens = nil
        }
        guard let tokens else { return false }
        // A grant that predates a scope addition can't serve current requests.
        return tokens.covers(OAuthConfiguration.scopes)
    }

    func store(_ newTokens: OAuthTokens) throws {
        try storage.save(newTokens)
        tokens = newTokens
    }

    func signOut() throws {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        try storage.clear()
    }

    var hasSession: Bool { tokens != nil }

    /// The access token to put in an `Authorization` header, refreshing first if needed.
    func validAccessToken() async throws -> String {
        guard let current = tokens else { throw AuthError.notSignedIn }
        guard current.isExpired else { return current.accessToken }

        if let refreshTask {
            return try await refreshTask.value.accessToken
        }

        let task = Task<OAuthTokens, Error> { [refreshToken = current.refreshToken] in
            try await self.performRefresh(refreshToken: refreshToken)
        }
        refreshTask = task

        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    /// Forces a refresh regardless of local expiry. Used when the API returns 401,
    /// which means the server disagrees with our expiry bookkeeping.
    func forceRefresh() async throws -> String {
        guard let current = tokens else { throw AuthError.notSignedIn }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        let task = Task<OAuthTokens, Error> { [refreshToken = current.refreshToken] in
            try await self.performRefresh(refreshToken: refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    private func performRefresh(refreshToken: String) async throws -> OAuthTokens {
        logger.info("Refreshing access token")

        let body = [
            "client_id": OAuthConfiguration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        do {
            let response = try await OAuthHTTP.postForm(
                to: OAuthConfiguration.tokenEndpoint,
                fields: body,
                using: urlSession
            )
            let refreshed = try response.tokens(existingRefreshToken: refreshToken)
            try store(refreshed)
            return refreshed
        } catch let error as AuthError {
            // invalid_grant means the refresh token is dead — revoked, or expired
            // because the consent screen is in External/Testing mode. Either way the
            // stored session is worthless, so clear it rather than retry forever.
            if case .tokenRequestFailed(_, let code, _) = error, code == "invalid_grant" {
                logger.error("Refresh token rejected (invalid_grant); clearing session")
                try? signOut()
                throw AuthError.reauthenticationRequired("the saved credential was revoked or expired")
            }
            throw error
        }
    }
}
