import Foundation

/// Form-encoded POSTs to Google's OAuth endpoints.
///
/// Kept separate from the Chat API client: the OAuth endpoints speak
/// `application/x-www-form-urlencoded` and have their own error envelope, and this
/// code must not depend on a token provider that in turn depends on it.
nonisolated enum OAuthHTTP {
    static func postForm(
        to url: URL,
        fields: [String: String],
        using session: URLSession
    ) async throws -> TokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(fields).utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.malformedResponse }

        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            throw AuthError.tokenRequestFailed(
                status: http.statusCode,
                error: payload?.error,
                description: payload?.errorDescription
            )
        }

        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthError.malformedResponse
        }
    }

    /// `URLComponents` percent-encoding is not correct for form bodies — it leaves
    /// `+` and `&` intact, which corrupts token values. Encode explicitly instead.
    static func formEncode(_ fields: [String: String]) -> String {
        fields
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
