import Foundation
import OSLog

/// A decoded Chat change, normalised from the Pub/Sub envelope.
nonisolated enum ChatEvent: Sendable {
    case messageCreated(ChatMessage)
    case messageUpdated(ChatMessage)
    case messageDeleted(name: String)
    case spaceChanged(name: String)
    /// Recognised but not yet acted on — reactions and memberships land in Phase 7.
    case unhandled(type: String)

    /// The space this event concerns, derived from the resource name.
    /// Message names are `spaces/{space}/messages/{message}`.
    var spaceName: String? {
        switch self {
        case .messageCreated(let message), .messageUpdated(let message):
            return Self.space(fromMessageName: message.name)
        case .messageDeleted(let name):
            return Self.space(fromMessageName: name)
        case .spaceChanged(let name):
            return name
        case .unhandled:
            return nil
        }
    }

    static func space(fromMessageName name: String) -> String? {
        let parts = name.split(separator: "/")
        guard parts.count >= 2, parts[0] == "spaces" else { return nil }
        return "spaces/\(parts[1])"
    }
}

/// Decodes Workspace Events payloads out of Pub/Sub messages.
///
/// The payload shape is documented loosely, so decoding is deliberately tolerant:
/// an unrecognised event is logged and skipped rather than throwing, because one
/// malformed payload must not stall the whole event stream.
nonisolated struct ChatEventDecoder: Sendable {
    private let logger = AppLog.logger("events")

    /// Envelope emitted by Workspace Events. Which field is populated depends on the
    /// event type; with `includeResource: true` the full object is inline.
    private struct Payload: Decodable {
        let message: ChatMessage?
        let space: EventSpace?

        struct EventSpace: Decodable { let name: String? }
    }

    func decode(_ pubsub: PubSubMessage) -> ChatEvent? {
        guard let type = pubsub.eventType else {
            logger.warning("Pub/Sub message without ce-type attribute; skipping")
            return nil
        }
        guard let data = pubsub.decodedData else {
            logger.warning("Event \(type) had no decodable payload; skipping")
            return nil
        }

        let payload = try? GoogleTransport.decoder.decode(Payload.self, from: data)

        switch type {
        case "google.workspace.chat.message.v1.created":
            guard let message = payload?.message else { return logMissing(type, data) }
            return .messageCreated(message)

        case "google.workspace.chat.message.v1.updated":
            guard let message = payload?.message else { return logMissing(type, data) }
            return .messageUpdated(message)

        case "google.workspace.chat.message.v1.deleted":
            // Deletion payloads carry only the resource name — the message is gone.
            guard let name = payload?.message?.name else { return logMissing(type, data) }
            return .messageDeleted(name: name)

        case "google.workspace.chat.space.v1.updated":
            guard let name = payload?.space?.name else { return logMissing(type, data) }
            return .spaceChanged(name: name)

        default:
            return .unhandled(type: type)
        }
    }

    /// Logs the raw payload once so an unexpected shape can be diagnosed from the
    /// console rather than guessed at.
    private func logMissing(_ type: String, _ data: Data) -> ChatEvent? {
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.error("Event \(type) payload did not match expected shape: \(raw, privacy: .private)")
        return nil
    }
}
