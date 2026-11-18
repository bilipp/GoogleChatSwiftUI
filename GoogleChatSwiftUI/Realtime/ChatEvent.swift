import Foundation
import OSLog

/// A decoded Chat change, normalised from the Pub/Sub envelope.
nonisolated enum ChatEvent: Sendable {
    case messageCreated(ChatMessage)
    case messageUpdated(ChatMessage)
    case messageDeleted(name: String)
    case spaceChanged(name: String)
    /// The user's read position moved somewhere — on the web, on a phone, or here.
    /// Several at once when Chat batches them.
    case readStatesChanged([ReadStateChange])
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
        case .readStatesChanged, .unhandled:
            return nil
        }
    }

    static func space(fromMessageName name: String) -> String? {
        let parts = name.split(separator: "/")
        guard parts.count >= 2, parts[0] == "spaces" else { return nil }
        return "spaces/\(parts[1])"
    }
}

/// One read mark from a read-state event, already reduced to the Chat resource it is
/// about.
nonisolated struct ReadStateChange: Sendable, Equatable {
    enum Target: Sendable, Equatable {
        case space(String)
        case thread(String)
    }

    /// Whose read state this is, e.g. `users/123`. Checked against the signed-in user
    /// before anything is applied: every colleague's subscription publishes into the
    /// same topic, so their read marks reach this queue too.
    let user: String
    let target: Target
    let lastReadTime: Date?

    /// Parses `users/U/spaces/S/spaceReadState` or
    /// `users/U/spaces/S/threads/T/threadReadState`.
    init?(resourceName: String, lastReadTime: Date?) {
        let parts = resourceName.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[0] == "users", parts[2] == "spaces" else { return nil }
        user = "users/\(parts[1])"
        self.lastReadTime = lastReadTime
        if parts.count == 5, parts[4] == "spaceReadState" {
            target = .space("spaces/\(parts[3])")
        } else if parts.count == 7, parts[4] == "threads", parts[6] == "threadReadState" {
            target = .thread("spaces/\(parts[3])/threads/\(parts[5])")
        } else {
            return nil
        }
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
        let spaceReadState: ReadState?
        let threadReadState: ReadState?
        /// The batch forms. Google documents the batch event types but shows no
        /// read-state batch example, so both the wrapped element shape its other
        /// batches use and a bare list are accepted.
        let spaceReadStates: [BatchElement]?
        let threadReadStates: [BatchElement]?

        struct EventSpace: Decodable { let name: String? }
        struct ReadState: Decodable {
            let name: String?
            let lastReadTime: Date?
        }
        struct BatchElement: Decodable {
            let state: ReadState?

            init(from decoder: Decoder) throws {
                let wrapped = try? decoder.container(keyedBy: Key.self)
                if let inner = (try? wrapped?.decodeIfPresent(ReadState.self, forKey: .spaceReadState))
                    ?? (try? wrapped?.decodeIfPresent(ReadState.self, forKey: .threadReadState)) {
                    state = inner
                } else {
                    state = try? ReadState(from: decoder)
                }
            }

            enum Key: String, CodingKey { case spaceReadState, threadReadState }
        }

        var readStates: [ReadState] {
            [spaceReadState, threadReadState].compactMap { $0 }
                + (spaceReadStates ?? []).compactMap(\.state)
                + (threadReadStates ?? []).compactMap(\.state)
        }
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

        case "google.workspace.chat.spaceReadState.v1.updated",
             "google.workspace.chat.spaceReadState.v1.batchUpdated",
             "google.workspace.chat.threadReadState.v1.updated",
             "google.workspace.chat.threadReadState.v1.batchUpdated":
            let changes = (payload?.readStates ?? []).compactMap { state in
                state.name.flatMap { ReadStateChange(resourceName: $0, lastReadTime: state.lastReadTime) }
            }
            guard !changes.isEmpty else { return logMissing(type, data) }
            return .readStatesChanged(changes)

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
