import SwiftUI

struct SignInView: View {
    let isSigningIn: Bool
    let errorMessage: String?
    let onSignIn: () -> Void

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
            .disabled(isSigningIn)

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
    SignInView(isSigningIn: false, errorMessage: nil, onSignIn: {})
        .frame(width: 640, height: 480)
}

#Preview("Error") {
    SignInView(
        isSigningIn: false,
        errorMessage: "Google rejected the token request (400): invalid_grant",
        onSignIn: {}
    )
    .frame(width: 640, height: 480)
}
