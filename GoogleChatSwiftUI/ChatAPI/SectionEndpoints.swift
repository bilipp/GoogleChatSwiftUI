import Foundation

// MARK: - Wire models

/// A grouping in the user's Chat navigation panel.
nonisolated struct ChatSection: Decodable, Sendable, Hashable {
    /// Resource name, e.g. `users/me/sections/default-spaces`.
    let name: String?
    /// Only populated for `CUSTOM_SECTION`.
    let displayName: String?
    let sortOrder: Int?
    /// `CUSTOM_SECTION`, `DEFAULT_DIRECT_MESSAGES`, `DEFAULT_SPACES`, `DEFAULT_APPS`.
    let type: String?

    /// System sections carry no `displayName`, so their labels come from the type.
    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        switch type {
        case "DEFAULT_DIRECT_MESSAGES": return "Direct messages"
        case "DEFAULT_SPACES": return "Spaces"
        case "DEFAULT_APPS": return "Apps"
        default: return "Section"
        }
    }
}

nonisolated struct ListSectionsResponse: Decodable, Sendable {
    let sections: [ChatSection]?
    let nextPageToken: String?
}

/// One space's membership of one section.
nonisolated struct ChatSectionItem: Decodable, Sendable, Hashable {
    /// Resource name, `users/{user}/sections/{section}/items/{item}`.
    let name: String?
    let space: String?

    /// Derived from `name` rather than trusting a separate field: the item's own
    /// resource path always contains its section, which makes the mapping reliable
    /// even as the payload's shape shifts.
    var sectionName: String? {
        guard let name else { return nil }
        let parts = name.split(separator: "/")
        guard parts.count >= 4, parts[2] == "sections" else { return nil }
        return "\(parts[0])/\(parts[1])/sections/\(parts[3])"
    }

    private enum CodingKeys: String, CodingKey {
        case name, space
    }

    /// `space` is documented only as "a space", without saying whether it arrives as a
    /// resource string or a nested object. Both are accepted rather than betting on one
    /// and silently dropping every item if the guess is wrong.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)

        if let flat = try? container.decodeIfPresent(String.self, forKey: .space) {
            space = flat
        } else if let nested = try? container.decodeIfPresent(NestedSpace.self, forKey: .space) {
            space = nested.name
        } else {
            space = nil
        }
    }

    private struct NestedSpace: Decodable {
        let name: String?
    }
}

nonisolated struct ListSectionItemsResponse: Decodable, Sendable {
    let sectionItems: [ChatSectionItem]?
    let nextPageToken: String?
}

/// Per-space notification preference for the signed-in user.
nonisolated struct SpaceNotificationSetting: Decodable, Sendable {
    let name: String?
    /// `ALL`, `MAIN_CONVERSATIONS`, `FOR_YOU`, or `OFF`.
    let notificationSetting: String?
    /// `MUTED` / `UNMUTED`. Developer Preview only, so absent for us — see
    /// `ChatClient.spaceNotificationSetting`.
    let muteSetting: String?
}

// MARK: - Endpoints

nonisolated extension ChatClient {
    /// The user's navigation sections, system and custom.
    /// - Parameter user: resource name, e.g. `users/123` or `users/me`.
    func listSections(user: String = "users/me") async throws -> [ChatSection] {
        var collected: [ChatSection] = []
        var token: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page = try await get("\(user)/sections", query: query, as: ListSectionsResponse.self)
            collected.append(contentsOf: page.sections ?? [])
            token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        } while token != nil
        return collected
    }

    /// Space-to-section assignments for every section at once.
    ///
    /// `users/me/sections/-` is the wildcard parent, so this is one paginated walk
    /// rather than a request per section — which matters when a user has a dozen
    /// custom sections.
    func listAllSectionItems(user: String = "users/me") async throws -> [ChatSectionItem] {
        var collected: [ChatSectionItem] = []
        var token: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page = try await get(
                "\(user)/sections/-/items",
                query: query,
                as: ListSectionItemsResponse.self
            )
            collected.append(contentsOf: page.sectionItems ?? [])
            token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        } while token != nil
        return collected
    }

    /// The user's notification preference for a space.
    ///
    /// `muteSetting` — the field that actually means "muted" in the web UI — is
    /// Developer Preview only and will be absent without membership of that
    /// programme. `notificationSetting == "OFF"` is the generally available signal
    /// that a space is silenced, so that is what this app treats as muted.
    func spaceNotificationSetting(spaceName: String) async throws -> SpaceNotificationSetting {
        let spaceID = spaceName.replacingOccurrences(of: "spaces/", with: "")
        return try await get(
            "users/me/spaces/\(spaceID)/spaceNotificationSetting",
            as: SpaceNotificationSetting.self
        )
    }
}
