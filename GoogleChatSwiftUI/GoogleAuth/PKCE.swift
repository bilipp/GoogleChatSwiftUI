import CryptoKit
import Foundation

/// A single-use PKCE (RFC 7636) verifier/challenge pair.
///
/// PKCE is what makes a secretless public client safe: the authorization code is
/// only redeemable by whoever holds the verifier, so intercepting the redirect is
/// not enough to steal the session.
nonisolated struct PKCE: Sendable {
    let verifier: String
    let challenge: String
    let method = "S256"

    init() {
        verifier = Self.randomURLSafeString(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }

    /// Cryptographically random, base64url-encoded. RFC 7636 requires 43–128 chars;
    /// 64 bytes encodes to 86.
    static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64URLEncodedString()
    }
}

nonisolated extension Data {
    /// base64url without padding, per RFC 4648 §5.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
