import Foundation
import Observation
import OSLog

/// Observable authentication state for the UI layer.
@MainActor
@Observable
final class AuthModel {
    enum State: Equatable {
        case restoring
        case signedOut
        case signingIn
        case signedIn(GoogleUserProfile)
    }

    private(set) var state: State = .restoring
    private(set) var errorMessage: String?

    let tokenProvider: TokenProvider
    private let authService: GoogleAuthService
    private let profileService: GoogleProfileService
    private let logger = AppLog.logger("auth")

    init() {
        let provider = TokenProvider()
        tokenProvider = provider
        authService = GoogleAuthService(tokenProvider: provider)
        profileService = GoogleProfileService(tokenProvider: provider)
    }

    /// Restores a persisted session on launch. Silent — a failure here just means
    /// showing the sign-in screen, not an error banner.
    func restore() async {
        state = .restoring
        guard await tokenProvider.restore() else {
            state = .signedOut
            return
        }
        do {
            let profile = try await profileService.currentUser()
            state = .signedIn(profile)
        } catch {
            logger.info("Session restore failed: \(error.localizedDescription)")
            state = .signedOut
        }
    }

    func signIn() async {
        errorMessage = nil
        state = .signingIn
        do {
            try await authService.signIn()
            let profile = try await profileService.currentUser()
            state = .signedIn(profile)
        } catch AuthError.userCancelled {
            state = .signedOut
        } catch {
            logger.error("Sign-in failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            state = .signedOut
        }
    }

    func signOut() async {
        do {
            try await tokenProvider.signOut()
        } catch {
            logger.error("Sign-out failed: \(error.localizedDescription)")
        }
        errorMessage = nil
        state = .signedOut
    }
}
