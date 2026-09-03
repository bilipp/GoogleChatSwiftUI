import Foundation
import OSLog

nonisolated struct DirectoryPerson: Sendable, Equatable {
    /// Chat-style resource name, e.g. `users/117864051793308773654`.
    let chatUserName: String
    let displayName: String
    let photoURL: String?
}

/// Resolves Chat user IDs to human names and photos via the People API.
///
/// This exists because the Chat API supplies neither: `spaces.members.list` returns
/// memberships with an empty `displayName`, and `Message.sender` is the same. The
/// numeric ID in Chat's `users/{id}` is the same identifier as People's `people/{id}`,
/// which is what makes the mapping possible at all.
nonisolated struct DirectoryService: Sendable {
    private let transport: GoogleTransport
    private let logger = AppLog.logger("directory")

    /// The API caps `batchGet` at 200 resource names. Kept lower because they travel
    /// as repeated query parameters and long URLs are their own failure mode.
    static let batchSize = 100

    init(transport: GoogleTransport) {
        self.transport = transport
    }

    /// Looks up people by Chat user resource name.
    ///
    /// Unresolvable IDs are simply absent from the result — deleted accounts and
    /// users outside the directory are expected, not exceptional.
    func people(forChatUserNames names: [String]) async throws -> [String: DirectoryPerson] {
        let unique = Array(Set(names))
        guard !unique.isEmpty else { return [:] }

        var resolved: [String: DirectoryPerson] = [:]

        for chunk in unique.chunked(into: Self.batchSize) {
            let batch = try await batchGet(chunk)
            resolved.merge(batch) { current, _ in current }
        }
        return resolved
    }

    private func batchGet(_ chatUserNames: [String]) async throws -> [String: DirectoryPerson] {
        var components = URLComponents(string: "https://people.googleapis.com/v1/people:batchGet")!
        var items = [URLQueryItem(name: "personFields", value: "names,photos")]
        for name in chatUserNames {
            let id = name.replacingOccurrences(of: "users/", with: "")
            items.append(URLQueryItem(name: "resourceNames", value: "people/\(id)"))
        }
        components.queryItems = items

        let response = try await transport.get(components.url!, as: BatchGetResponse.self)

        var resolved: [String: DirectoryPerson] = [:]
        for entry in response.responses ?? [] {
            guard let person = entry.person,
                  let resourceName = person.resourceName,
                  let displayName = person.names?.first?.displayName,
                  !displayName.isEmpty
            else { continue }

            let id = resourceName.replacingOccurrences(of: "people/", with: "")
            resolved["users/\(id)"] = DirectoryPerson(
                chatUserName: "users/\(id)",
                displayName: displayName,
                photoURL: Self.profilePhotoURL(from: person.photos)
            )
        }
        return resolved
    }

    /// The photo the person actually set, or nil where all the API offers is a
    /// placeholder.
    ///
    /// Taking `photos.first` is the obvious thing and the wrong one. `people:batchGet`
    /// reads from the caller's own contacts *and* from the directory profile, and returns
    /// one photo entry per source that has one. For a colleague who also happens to sit
    /// in the caller's Google Contacts, the contact entry sorts first and is flagged
    /// `default` — Google's grey silhouette, served from a URL an order of magnitude
    /// longer than a real one. So `first` drew a silhouette over the initials for exactly
    /// those people, while everyone else in the same workspace rendered their real face.
    ///
    /// Hence both rules here. Anything flagged `default` is discarded rather than ranked
    /// last: a placeholder is not a worse photo of someone, it is the absence of one, and
    /// ``Avatar`` says what to do about that — initials, which at least identify the
    /// person. Among what survives, a profile source wins, because that is where the
    /// photo someone chose for their account lives; a contact photo is whatever the
    /// *caller* happened to save for them.
    static func profilePhotoURL(from photos: [BatchGetResponse.Person.Photo]?) -> String? {
        let real = (photos ?? []).filter { photo in
            photo.isDefault != true && !(photo.url ?? "").isEmpty
        }
        let fromProfile = real.first { photo in
            guard let type = photo.metadata?.source?.type else { return false }
            return type == "PROFILE" || type == "DOMAIN_PROFILE"
        }
        return (fromProfile ?? real.first)?.url
    }

    /// Internal rather than private so ``profilePhotoURL(from:)`` can be tested against
    /// a real payload rather than a re-typed stand-in for one.
    struct BatchGetResponse: Decodable {
        struct Entry: Decodable {
            let httpStatusCode: Int?
            let person: Person?
            let requestedResourceName: String?
        }
        struct Person: Decodable {
            struct Name: Decodable { let displayName: String? }
            struct Photo: Decodable {
                struct Metadata: Decodable {
                    struct Source: Decodable { let type: String? }
                    let source: Source?
                }
                let url: String?
                let metadata: Metadata?
                /// True for Google's generic silhouette. Spelled `default` in the JSON,
                /// which is a keyword here.
                let isDefault: Bool?

                enum CodingKeys: String, CodingKey {
                    case url, metadata
                    case isDefault = "default"
                }
            }
            let resourceName: String?
            let names: [Name]?
            let photos: [Photo]?
        }
        let responses: [Entry]?
    }
}

nonisolated extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
