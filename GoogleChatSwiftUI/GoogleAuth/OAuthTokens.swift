import Foundation

/// The credential set persisted between launches.
nonisolated struct OAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    /// Google omits this on refresh responses, so it must be carried forward.
    var refreshToken: String
    var expiresAt: Date
    var scopes: [String]

    /// Treat tokens as stale a minute early so an in-flight request can't expire mid-call.
    static let expiryMargin: TimeInterval = 60

    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-Self.expiryMargin)
    }

    /// Whether the stored grant covers everything the app currently asks for.
    /// A false result means scopes were added since the user last consented.
    func covers(_ required: [String]) -> Bool {
        Set(required).isSubset(of: Set(scopes))
    }
}

/// Wire format of Google's token endpoint response.
nonisolated struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double
    let scope: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }

    /// - Parameter existingRefreshToken: carried forward when the response omits one,
    ///   which is the normal case for a refresh grant.
    func tokens(existingRefreshToken: String?) throws -> OAuthTokens {
        guard let refresh = refreshToken ?? existingRefreshToken else {
            throw AuthError.reauthenticationRequired("no refresh token was issued")
        }
        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scopes: scope?.split(separator: " ").map(String.init) ?? []
        )
    }
}

/// Wire format of Google's OAuth error payload.
nonisolated struct TokenErrorResponse: Decodable, Sendable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
