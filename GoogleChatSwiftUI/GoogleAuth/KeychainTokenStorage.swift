import Foundation

/// Persists the OAuth token set in the login keychain.
///
/// The app is sandboxed, so these items land in a keychain access group derived from
/// the app identifier automatically — no `keychain-access-groups` entitlement needed,
/// and no other app can read them.
///
/// That holds for a team-signed build. An ad-hoc one (`DEVELOPMENT_TEAM` empty) gets no
/// `application-identifier` entitlement at all, and its designated requirement is the
/// binary hash alone — so every rebuild reads as a different app and cannot load what
/// the last one saved. The effect is a fresh sign-in per rebuild, which is a known cost
/// of building without a team rather than something to work around here. See
/// `docs/SETUP.md`.
nonisolated struct KeychainTokenStorage: Sendable {
    private let service: String
    private let account: String

    init(service: String = "GoogleChatSwiftUI.OAuth", account: String = "google") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> OAuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw AuthError.malformedResponse }
            return try JSONDecoder().decode(OAuthTokens.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychain(status)
        }
    }

    func save(_ tokens: OAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)

        // Update in place if present, otherwise insert. SecItemAdd fails with
        // errSecDuplicateItem rather than overwriting, so the update path comes first.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AuthError.keychain(updateStatus) }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AuthError.keychain(addStatus) }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychain(status)
        }
    }
}
