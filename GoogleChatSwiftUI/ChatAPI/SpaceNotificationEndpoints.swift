import Foundation

/// The signed-in user's notification and mute settings for one space.
///
/// `muteSetting` is the mute the web client and the phone app show and set. It is a
/// separate switch from `notificationSetting`: a muted space keeps its notification
/// level, and a space set to notify about nothing is not muted.
nonisolated struct SpaceNotificationSetting: Codable, Sendable {
    var name: String?
    /// `ALL`, `MAIN_CONVERSATIONS`, `FOR_YOU` or `OFF`.
    var notificationSetting: String?
    /// `MUTED` or `UNMUTED`.
    var muteSetting: String?

    var isMuted: Bool { muteSetting == "MUTED" }
}

private nonisolated struct MuteSettingBody: Encodable, Sendable {
    let muteSetting: String
}

nonisolated extension ChatClient {
    /// `users/me/spaces/{space}/spaceNotificationSetting`. The API has no list method,
    /// so this is one call per space.
    private static func notificationSettingPath(for spaceName: String) -> String {
        let spaceID = spaceName.hasPrefix("spaces/") ? String(spaceName.dropFirst(7)) : spaceName
        return "users/me/spaces/\(spaceID)/spaceNotificationSetting"
    }

    func spaceNotificationSetting(spaceName: String) async throws -> SpaceNotificationSetting {
        try await get(
            Self.notificationSettingPath(for: spaceName),
            as: SpaceNotificationSetting.self
        )
    }

    /// Mutes or unmutes the space for this user everywhere they use Chat.
    @discardableResult
    func setMuteSetting(spaceName: String, muted: Bool) async throws -> SpaceNotificationSetting {
        try await patch(
            Self.notificationSettingPath(for: spaceName),
            updateMask: "muteSetting",
            body: MuteSettingBody(muteSetting: muted ? "MUTED" : "UNMUTED"),
            as: SpaceNotificationSetting.self
        )
    }
}
