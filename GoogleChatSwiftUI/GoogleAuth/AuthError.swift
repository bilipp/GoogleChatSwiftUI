import Foundation

nonisolated enum AuthError: LocalizedError, Equatable {
    case userCancelled
    case missingAuthorizationCode
    case stateMismatch
    case notSignedIn
    /// The refresh token is gone or was revoked — only a full re-consent recovers.
    case reauthenticationRequired(String)
    case tokenRequestFailed(status: Int, error: String?, description: String?)
    case malformedResponse
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Sign-in was cancelled."
        case .missingAuthorizationCode:
            return "Google's redirect did not include an authorization code."
        case .stateMismatch:
            return "The sign-in response did not match the request. It may have been tampered with."
        case .notSignedIn:
            return "You are not signed in."
        case .reauthenticationRequired(let reason):
            return "Your session expired and could not be renewed automatically. Please sign in again. (\(reason))"
        case .tokenRequestFailed(let status, let error, let description):
            let detail = description ?? error
            if let detail {
                return "Google rejected the token request (\(status)): \(detail)"
            }
            return "Google rejected the token request (HTTP \(status))."
        case .malformedResponse:
            return "Google returned a response this app could not read."
        case .keychain(let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
            return "Keychain error \(status): \(message)"
        }
    }

    /// Whether the only recovery is a fresh interactive sign-in.
    var requiresInteractiveSignIn: Bool {
        switch self {
        case .notSignedIn, .reauthenticationRequired: true
        default: false
        }
    }
}
