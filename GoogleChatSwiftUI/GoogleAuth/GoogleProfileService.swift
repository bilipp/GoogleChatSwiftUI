import Foundation

/// The signed-in user's basic identity.
///
/// Chat's own `Message.sender` carries no avatar, so profile photos come from the
/// People API instead.
nonisolated struct GoogleUserProfile: Sendable, Equatable {
    var displayName: String
    var photoURL: URL?
    /// People API resource name, e.g. `people/c123456789`.
    var resourceName: String
}

/// Reads the signed-in user's profile from the People API.
nonisolated struct GoogleProfileService: Sendable {
    private let tokenProvider: TokenProvider
    private let urlSession: URLSession

    init(tokenProvider: TokenProvider, urlSession: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
    }

    func currentUser() async throws -> GoogleUserProfile {
        var components = URLComponents(
            string: "https://people.googleapis.com/v1/people/me"
        )!
        components.queryItems = [
            URLQueryItem(name: "personFields", value: "names,photos")
        ]

        var request = URLRequest(url: components.url!)
        let token = try await tokenProvider.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.malformedResponse }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw AuthError.tokenRequestFailed(
                status: http.statusCode,
                error: "people.get",
                description: body
            )
        }

        let payload = try JSONDecoder().decode(PeopleResponse.self, from: data)
        return GoogleUserProfile(
            displayName: payload.names?.first?.displayName ?? "Unknown",
            photoURL: payload.photos?.first?.url.flatMap(URL.init(string:)),
            resourceName: payload.resourceName ?? ""
        )
    }

    private struct PeopleResponse: Decodable {
        struct Name: Decodable { let displayName: String? }
        struct Photo: Decodable { let url: String? }
        let resourceName: String?
        let names: [Name]?
        let photos: [Photo]?
    }
}
