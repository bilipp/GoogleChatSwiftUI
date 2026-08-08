import SwiftUI

struct SignInView: View {
    let isSigningIn: Bool
    let errorMessage: String?
    let onSignIn: () -> Void

    /// A checkout with no `Config/Secrets.xcconfig` still builds and runs, so the
    /// first thing it can do wrong is send placeholder credentials to Google and come
    /// back with `invalid_client`. Saying so here costs one line and saves the search.
    var isConfigured: Bool = OAuthConfiguration.isConfigured

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Google Chat")
                    .font(.largeTitle.weight(.semibold))
                Text("Sign in with your Google Workspace account to read and send messages.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            Button(action: onSignIn) {
                if isSigningIn {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Signing in…")
                    }
                    .frame(maxWidth: 180)
                } else {
                    Text("Sign in with Google")
                        .frame(maxWidth: 180)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSigningIn || !isConfigured)

            if !isConfigured {
                Text("No Google Cloud project is configured. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`, fill in your own client ID and project, and rebuild — see `docs/SETUP.md`.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .textSelection(.enabled)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .textSelection(.enabled)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Idle") {
    SignInView(isSigningIn: false, errorMessage: nil, onSignIn: {}, isConfigured: true)
        .frame(width: 640, height: 480)
}

#Preview("Unconfigured") {
    SignInView(isSigningIn: false, errorMessage: nil, onSignIn: {}, isConfigured: false)
        .frame(width: 640, height: 480)
}

#Preview("Error") {
    SignInView(
        isSigningIn: false,
        errorMessage: "Google rejected the token request (400): invalid_grant",
        onSignIn: {},
        isConfigured: true
    )
    .frame(width: 640, height: 480)
}
