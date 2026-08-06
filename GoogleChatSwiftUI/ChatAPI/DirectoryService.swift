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
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "directory")

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
                photoURL: person.photos?.first?.url
            )
        }
        return resolved
    }

    private struct BatchGetResponse: Decodable {
        struct Entry: Decodable {
            let httpStatusCode: Int?
            let person: Person?
            let requestedResourceName: String?
        }
        struct Person: Decodable {
            struct Name: Decodable { let displayName: String? }
            struct Photo: Decodable { let url: String? }
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
