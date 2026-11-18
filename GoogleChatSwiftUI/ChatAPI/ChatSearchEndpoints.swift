import Foundation

/// One hit from `spaces.messages.search`.
nonisolated struct MessageSearchHit: Decodable, Sendable {
    let message: ChatMessage
}

nonisolated struct SearchMessagesResponse: Decodable, Sendable {
    let results: [MessageSearchHit]?
    let nextPageToken: String?
}

private nonisolated struct SearchMessagesBody: Encodable, Sendable {
    let filter: String
    let pageSize: Int
    let pageToken: String?
    let orderBy: String
}

nonisolated extension ChatClient {
    /// Server-side full-text search across every conversation the user can see.
    ///
    /// Chat leaves out muted spaces and messages posted by apps, so this adds to the
    /// local cache search and does not replace it.
    func searchMessages(
        filter: String,
        pageSize: Int = 50,
        pageToken: String? = nil
    ) async throws -> SearchMessagesResponse {
        try await post(
            "spaces/-/messages:search",
            body: SearchMessagesBody(
                filter: filter,
                pageSize: min(pageSize, 100),
                pageToken: pageToken,
                orderBy: "createTime desc"
            ),
            as: SearchMessagesResponse.self
        )
    }

    /// Builds a `messages.search` filter from what someone typed in the search field.
    ///
    /// The words go in as plain keywords, which Chat ANDs together. Quotes and
    /// backslashes are dropped so the filter cannot be broken by stray punctuation.
    /// The filter is capped at 1000 characters, so long input is trimmed.
    /// Returns nil when no keyword is left.
    static func messageSearchFilter(query: String, spaceName: String?) -> String? {
        let words = query
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "\\", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else { return nil }

        let scope = spaceName.map { " AND space.name = \"\($0)\"" } ?? ""
        var keywords = ""
        for word in words {
            let next = keywords.isEmpty ? word : keywords + " " + word
            guard next.count + scope.count <= 1000 else { break }
            keywords = next
        }
        guard !keywords.isEmpty else { return nil }
        return keywords + scope
    }
}
