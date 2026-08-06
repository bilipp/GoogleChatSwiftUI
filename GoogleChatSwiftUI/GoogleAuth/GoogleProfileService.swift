import Foundation

/// The signed-in user's basic identity.
///
/// Chat's own `Message.sender` carries no avatar, so profile photos come from the
/// People API instead.
nonisolated struct GoogleUserProfile: Sendable, Equatable {
    var displayName: String
    var photoURL: URL?
    /// People API resource name, e.g. `people/123456789012345678901`.
    var resourceName: String
    /// Numeric Google profile ID, from the PROFILE metadata source.
    var profileID: String?

    /// The identity Chat uses for `Message.sender.name`, e.g. `users/1234567890`.
    ///
    /// People and Chat namespace users differently — a People `resourceName` cannot
    /// be compared against a Chat sender directly. The numeric PROFILE source ID is
    /// the value both APIs agree on.
    var chatUserName: String? {
        profileID.map { "users/\($0)" }
    }
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
            URLQueryItem(name: "personFields", value: "names,photos,metadata")
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
        let profileID = payload.metadata?.sources?
            .first { $0.type == "PROFILE" }?
            .id

        return GoogleUserProfile(
            displayName: payload.names?.first?.displayName ?? "Unknown",
            photoURL: payload.photos?.first?.url.flatMap(URL.init(string:)),
            resourceName: payload.resourceName ?? "",
            profileID: profileID
        )
    }

    private struct PeopleResponse: Decodable {
        struct Name: Decodable { let displayName: String? }
        struct Photo: Decodable { let url: String? }
        struct Source: Decodable {
            let type: String?
            let id: String?
        }
        struct Metadata: Decodable { let sources: [Source]? }

        let resourceName: String?
        let names: [Name]?
        let photos: [Photo]?
        let metadata: Metadata?
    }
}
