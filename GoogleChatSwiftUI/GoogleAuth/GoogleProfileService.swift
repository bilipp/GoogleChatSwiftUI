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
    /// Primary address, which names this person's Pub/Sub subscription.
    /// See ``OAuthConfiguration/subscriptionID(for:)``.
    var emailAddress: String?

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

    private static let baseFields = "names,photos,metadata"

    func currentUser() async throws -> GoogleUserProfile {
        // The address is asked for in the same round-trip, but is not allowed to cost
        // the profile. A token minted before `userinfo.email` was requested — anyone's
        // stored session at the point this was added — is refused the field rather than
        // given a response without it, and losing the profile to that would drop the
        // person back to the sign-in screen on launch for no reason they could act on.
        // So a refusal retries for the fields that were always readable, and realtime
        // reports the missing queue instead.
        let payload: PeopleResponse
        do {
            payload = try await fetch(personFields: "\(Self.baseFields),emailAddresses")
        } catch let error as AuthError {
            guard case .tokenRequestFailed(403, _, _) = error else { throw error }
            payload = try await fetch(personFields: Self.baseFields)
        }

        let profileID = payload.metadata?.sources?
            .first { $0.type == "PROFILE" }?
            .id

        // People returns addresses in no guaranteed order, so the primary one is taken
        // from the metadata flag rather than by position, falling back to the first.
        let addresses = payload.emailAddresses ?? []
        let emailAddress = (addresses.first { $0.metadata?.primary == true } ?? addresses.first)?.value

        return GoogleUserProfile(
            displayName: payload.names?.first?.displayName ?? "Unknown",
            photoURL: payload.photos?.first?.url.flatMap(URL.init(string:)),
            resourceName: payload.resourceName ?? "",
            profileID: profileID,
            emailAddress: emailAddress
        )
    }

    private func fetch(personFields: String) async throws -> PeopleResponse {
        var components = URLComponents(
            string: "https://people.googleapis.com/v1/people/me"
        )!
        components.queryItems = [
            URLQueryItem(name: "personFields", value: personFields)
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

        return try JSONDecoder().decode(PeopleResponse.self, from: data)
    }

    private struct PeopleResponse: Decodable {
        struct Name: Decodable { let displayName: String? }
        struct Photo: Decodable { let url: String? }
        struct Source: Decodable {
            let type: String?
            let id: String?
        }
        struct Metadata: Decodable { let sources: [Source]? }
        struct EmailAddress: Decodable {
            struct FieldMetadata: Decodable { let primary: Bool? }
            let value: String?
            let metadata: FieldMetadata?
        }

        let resourceName: String?
        let names: [Name]?
        let photos: [Photo]?
        let metadata: Metadata?
        let emailAddresses: [EmailAddress]?
    }
}
