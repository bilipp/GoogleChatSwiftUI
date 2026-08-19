import Foundation
import OSLog

/// A meeting the app has just created.
nonisolated struct MeetSpace: Sendable, Equatable {
    /// Meet's own resource name, e.g. `spaces/jQCFfuBOdN5z`. Confusingly shaped like a
    /// Chat space name and unrelated to one: this identifies the meeting, not the
    /// conversation the link gets posted into.
    let name: String
    /// What a person clicks, e.g. `https://meet.google.com/abc-mnop-xyz`.
    let joinURL: URL
}

/// Meet's answer to `spaces.create`, reduced to the two fields this app reads.
///
/// `meetingCode` is deliberately not among them. It is the dashed code the URL already
/// ends in, and Meet documents it as expiring 365 days after last use and as reusable
/// for a different space afterwards — so it is a display detail with a shelf life, not
/// an identifier worth carrying beside the link.
nonisolated struct MeetSpaceResponse: Decodable, Sendable {
    let name: String?
    let meetingUri: String?

    /// The usable value, or nil when Meet answered 200 without a link to join.
    ///
    /// Both fields are documented as output-only and always present, so nil here means
    /// the response was not the one documented rather than an ordinary state — which is
    /// why the caller turns it into an error instead of a link-less meeting.
    var space: MeetSpace? {
        guard let name, let meetingUri, let joinURL = URL(string: meetingUri) else { return nil }
        return MeetSpace(name: name, joinURL: joinURL)
    }
}

/// Why creating a meeting failed, in terms of what the person reading it can do.
///
/// `ChatAPIError` already carries Google's own message, which is usually the informative
/// part — but it says "Chat API" in front of it, and for the one failure people will
/// actually hit here that is both wrong and unhelpful. Adding a meeting is the newest
/// scope this app asks for, so the common case is a grant made before it existed.
nonisolated enum MeetError: LocalizedError {
    /// Google refused the call: the grant predates the meeting scope, or the Meet API
    /// is not enabled for the Cloud project this build points at.
    case notAuthorized(any Error)
    /// A 200 with nothing to join.
    case noLinkReturned

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let underlying):
            """
            Couldn't create a video meeting: \(underlying.localizedDescription)
            Signing out and back in grants the meeting scope; if it still fails, the Meet \
            API is not enabled for this Cloud project.
            """
        case .noLinkReturned:
            "Google created a video meeting but returned no link to join it."
        }
    }
}

/// Creates Meet links, one per meeting started from the composer.
///
/// A stateless value like ``DirectoryService`` rather than a caching actor like
/// ``DriveMetadataService``: there is nothing to cache. Every call is meant to produce a
/// *new* meeting, and reusing one link for two conversations would put two sets of
/// people in the same room.
///
/// `meetings.space.created` is the narrowest scope Meet offers. It grants this app the
/// spaces it creates itself and nothing else — no reading meetings made elsewhere, no
/// conference records, no recordings or transcripts.
nonisolated struct MeetSpaceService: Sendable {
    private let transport: GoogleTransport
    private let logger = AppLog.logger("meet")

    private static let spacesEndpoint = URL(string: "https://meet.googleapis.com/v2/spaces")!

    init(transport: GoogleTransport) {
        self.transport = transport
    }

    /// Creates an empty meeting space and returns its link.
    ///
    /// The body is empty on purpose. `config.accessType` decides who can walk in without
    /// knocking, and leaving it unset is what defers that to the workspace's own policy —
    /// the same default a meeting started from Chat or Calendar gets. Setting it here
    /// would quietly make this app's meetings more open, or more closed, than every other
    /// meeting in the org.
    func createSpace() async throws -> MeetSpace {
        do {
            let response = try await transport.post(
                Self.spacesEndpoint,
                body: EmptyRequest(),
                as: MeetSpaceResponse.self
            )
            guard let space = response.space else { throw MeetError.noLinkReturned }
            logger.info("Created Meet space \(space.name, privacy: .public)")
            return space
        } catch let error as ChatAPIError where error.status == 403 {
            // Both plausible causes are stated in the message rather than guessed at:
            // Google's own text distinguishes an insufficient scope from a disabled API,
            // and neither is something the app can fix by retrying.
            throw MeetError.notAuthorized(error)
        }
    }
}

/// `{}` — Meet's create takes a `Space` body, and every field of the one this app sends
/// is either output-only or deliberately left to workspace policy.
private nonisolated struct EmptyRequest: Encodable, Sendable {}
