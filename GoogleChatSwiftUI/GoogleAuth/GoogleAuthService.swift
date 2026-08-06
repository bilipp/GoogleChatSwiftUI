import AuthenticationServices
import Foundation
import OSLog

/// Drives the interactive OAuth 2.0 authorization-code flow with PKCE.
///
/// `ASWebAuthenticationSession` intercepts the custom-scheme redirect itself, so the
/// scheme deliberately is *not* registered in `CFBundleURLTypes` — doing so would let
/// an unrelated browser hand the code to the app out of band.
@MainActor
final class GoogleAuthService: NSObject {
    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "auth")

    /// Held for the lifetime of the flow; releasing it cancels the session.
    private var activeSession: ASWebAuthenticationSession?

    init(tokenProvider: TokenProvider, urlSession: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
        super.init()
    }

    /// Presents Google's consent UI and exchanges the resulting code for tokens.
    func signIn() async throws {
        let pkce = PKCE()
        let state = PKCE.randomURLSafeString(byteCount: 32)

        let callbackURL = try await presentAuthorization(pkce: pkce, state: state)
        let code = try extractCode(from: callbackURL, expectedState: state)
        let tokens = try await exchange(code: code, verifier: pkce.verifier)

        try await tokenProvider.store(tokens)
        logger.info("Sign-in complete; granted \(tokens.scopes.count) scopes")
    }

    // MARK: - Authorization

    private func presentAuthorization(pkce: PKCE, state: String) async throws -> URL {
        var components = URLComponents(url: OAuthConfiguration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfiguration.clientID),
            URLQueryItem(name: "redirect_uri", value: OAuthConfiguration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: OAuthConfiguration.scopeString),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            // Required for a refresh token on the very first consent.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let authURL = components.url!

        // The session is released once the flow ends, whichever way it ends. This runs
        // back on the main actor after the continuation resumes.
        defer { activeSession = nil }

        return try await withCheckedThrowingContinuation { continuation in
            // Explicitly typed as @Sendable so it is *not* inferred @MainActor.
            // AuthenticationServices delivers this on an XPC reply queue, so a
            // main-actor-isolated closure would trap the executor check. It must
            // therefore touch nothing but the continuation.
            let handler: @Sendable (URL?, (any Error)?) -> Void = { callbackURL, error in
                if let error {
                    let isCancellation = (error as? ASWebAuthenticationSessionError)?.code
                        == .canceledLogin
                    continuation.resume(throwing: isCancellation ? AuthError.userCancelled : error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.missingAuthorizationCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: OAuthConfiguration.redirectScheme,
                completionHandler: handler
            )

            session.presentationContextProvider = self
            // Reuse the browser's existing Google session so a signed-in user only
            // has to approve, not retype credentials.
            session.prefersEphemeralWebBrowserSession = false

            activeSession = session

            guard session.start() else {
                activeSession = nil
                continuation.resume(throwing: AuthError.userCancelled)
                return
            }
        }
    }

    private func extractCode(from url: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        if let error = items.first(where: { $0.name == "error" })?.value {
            if error == "access_denied" { throw AuthError.userCancelled }
            throw AuthError.tokenRequestFailed(status: 400, error: error, description: nil)
        }

        // Verifying state closes the CSRF hole where an attacker's code gets
        // swapped in for the user's.
        guard let returnedState = items.first(where: { $0.name == "state" })?.value,
              returnedState == expectedState
        else { throw AuthError.stateMismatch }

        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.missingAuthorizationCode
        }
        return code
    }

    // MARK: - Token exchange

    private func exchange(code: String, verifier: String) async throws -> OAuthTokens {
        let response = try await OAuthHTTP.postForm(
            to: OAuthConfiguration.tokenEndpoint,
            fields: [
                "client_id": OAuthConfiguration.clientID,
                "code": code,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": OAuthConfiguration.redirectURI,
            ],
            using: urlSession
        )
        return try response.tokens(existingRefreshToken: nil)
    }
}

extension GoogleAuthService: ASWebAuthenticationPresentationContextProviding {
    /// The protocol is declared `NS_SWIFT_UI_ACTOR`, so this requirement is already
    /// main-actor isolated — no `nonisolated` hop or `assumeIsolated` needed.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }
}
