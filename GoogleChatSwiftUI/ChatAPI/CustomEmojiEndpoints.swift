import Foundation

nonisolated struct ListCustomEmojisResponse: Decodable, Sendable {
    let customEmojis: [ChatEmoji.CustomEmoji]?
    let nextPageToken: String?
}

nonisolated extension ChatClient {
    /// Every custom emoji in the user's organisation, all pages.
    func customEmojis() async throws -> [ChatEmoji.CustomEmoji] {
        var collected: [ChatEmoji.CustomEmoji] = []
        var token: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "200")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page = try await get("customEmojis", query: query, as: ListCustomEmojisResponse.self)
            collected.append(contentsOf: page.customEmojis ?? [])
            token = page.nextPageToken
        } while !(token ?? "").isEmpty
        return collected
    }
}
