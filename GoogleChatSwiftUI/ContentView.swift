import SwiftUI

struct ContentView: View {
    @Environment(AuthModel.self) private var auth

    var body: some View {
        switch auth.state {
        case .restoring:
            ProgressView("Restoring session…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .signedOut, .signingIn:
            SignInView(
                isSigningIn: auth.state == .signingIn,
                errorMessage: auth.errorMessage,
                onSignIn: { Task { await auth.signIn() } }
            )

        case .signedIn:
            SpacesListView()
        }
    }
}
