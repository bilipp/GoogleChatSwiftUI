import Foundation

/// The signed-in user's own presence and custom status, from `users/me/availability`.
///
/// Chat only exposes this for the caller. Nobody else's availability can be read, so
/// it drives the account menu and nothing in the sidebar or transcript.
nonisolated struct ChatAvailability: Decodable, Sendable, Equatable {
    enum State: String, Decodable, Sendable {
        case active = "ACTIVE"
        case idle = "IDLE"
        case away = "AWAY"
        case doNotDisturb = "DO_NOT_DISTURB"
        case unspecified = "STATE_UNSPECIFIED"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .unspecified
        }
    }

    struct CustomStatus: Codable, Sendable, Equatable {
        struct Emoji: Codable, Sendable, Equatable {
            let unicode: String?
        }

        let text: String?
        let emoji: Emoji?
        let expireTime: Date?
    }

    let state: State?
    /// When a timed state such as Do Not Disturb ends.
    let expireTime: Date?
    let customStatus: CustomStatus?

    /// A custom status worth showing: one with text or an emoji that has not expired.
    var visibleCustomStatus: CustomStatus? {
        guard let status = customStatus,
              !(status.text ?? "").isEmpty || !(status.emoji?.unicode ?? "").isEmpty
        else { return nil }
        if let end = status.expireTime, end <= .now { return nil }
        return status
    }
}

/// One change the user can make to their own availability.
nonisolated enum AvailabilityChange: Sendable, Equatable {
    case active
    case away
    case doNotDisturb(until: Date)
    /// Nil text and emoji clear the status.
    case customStatus(text: String?, emoji: String?, until: Date?)
}

private nonisolated struct AvailabilityExpiryBody: Encodable, Sendable {
    let expireTime: String?
}

private nonisolated struct EmptyAvailabilityBody: Encodable, Sendable {}

private nonisolated struct CustomStatusBody: Encodable, Sendable {
    struct Status: Encodable, Sendable {
        struct Emoji: Encodable, Sendable { let unicode: String }
        let text: String?
        let emoji: Emoji?
        let expireTime: String?
    }

    let customStatus: Status
}

nonisolated extension ChatClient {
    private static let availabilityPath = "users/me/availability"

    func availability() async throws -> ChatAvailability {
        try await get(Self.availabilityPath, as: ChatAvailability.self)
    }

    func markAsActive() async throws -> ChatAvailability {
        try await post(
            "\(Self.availabilityPath):markAsActive",
            body: EmptyAvailabilityBody(),
            as: ChatAvailability.self
        )
    }

    func markAsAway() async throws -> ChatAvailability {
        try await post(
            "\(Self.availabilityPath):markAsAway",
            body: EmptyAvailabilityBody(),
            as: ChatAvailability.self
        )
    }

    /// Do Not Disturb always ends. Chat refuses it without an end time.
    func markAsDoNotDisturb(until end: Date) async throws -> ChatAvailability {
        try await post(
            "\(Self.availabilityPath):markAsDoNotDisturb",
            body: AvailabilityExpiryBody(expireTime: end.formatted(.iso8601)),
            as: ChatAvailability.self
        )
    }

    /// Sets or clears the custom status. Pass nil text and emoji to clear it.
    /// Chat caps the text at 64 characters.
    func setCustomStatus(text: String?, emoji: String?, until end: Date?) async throws -> ChatAvailability {
        let body = CustomStatusBody(customStatus: .init(
            text: text.map { String($0.prefix(64)) },
            emoji: emoji.map { .init(unicode: $0) },
            expireTime: end?.formatted(.iso8601)
        ))
        return try await patch(
            Self.availabilityPath,
            updateMask: "customStatus",
            body: body,
            as: ChatAvailability.self
        )
    }
}
