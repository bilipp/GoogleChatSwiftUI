import Foundation
import Testing

@testable import GoogleChatSwiftUI

/// Starting a meeting is two APIs in a row — Meet makes the space, Chat carries the link —
/// and the seam between them is where the interesting failures live. Meet answering 200
/// with no link, a grant that predates the scope, a draft that has to survive a meeting
/// that never got made.
///
/// These pin the parts that can be tested without a network: what the response decodes to,
/// what the message ends up saying, and that the scope the call needs is actually asked
/// for at sign-in.
struct MeetLinkTests {
    // MARK: - What Meet answers

    /// Shaped as the API documents it, including the fields this app deliberately ignores,
    /// so decoding stays correct as it grows rather than being tested against a subset.
    private func decode(_ json: String) throws -> MeetSpaceResponse {
        try GoogleTransport.decoder.decode(MeetSpaceResponse.self, from: Data(json.utf8))
    }

    @Test func createResponseYieldsAJoinableLink() throws {
        let response = try decode("""
        {
          "name": "spaces/jQCFfuBOdN5z",
          "meetingUri": "https://meet.google.com/abc-mnop-xyz",
          "meetingCode": "abc-mnop-xyz",
          "config": { "accessType": "TRUSTED", "entryPointAccess": "ALL" }
        }
        """)

        let space = try #require(response.space)
        #expect(space.name == "spaces/jQCFfuBOdN5z")
        #expect(space.joinURL.absoluteString == "https://meet.google.com/abc-mnop-xyz")
    }

    /// A 200 with no `meetingUri` is not a meeting without a link — it is a response that
    /// does not match what Meet documents. Reported as an error rather than posted as an
    /// empty message.
    @Test func responseWithoutAURIHasNoSpace() throws {
        #expect(try decode(#"{"name":"spaces/jQCFfuBOdN5z"}"#).space == nil)
        #expect(try decode(#"{"meetingUri":"https://meet.google.com/abc-mnop-xyz"}"#).space == nil)
        #expect(try decode("{}").space == nil)
    }

    /// The one failure people will actually hit — a grant made before this scope existed —
    /// has to keep Google's own explanation, which is the part that identifies it.
    @Test func refusalKeepsGoogleReason() throws {
        let underlying = ChatAPIError(
            status: 403,
            googleStatus: "PERMISSION_DENIED",
            message: "Request had insufficient authentication scopes."
        )
        let described = try #require(MeetError.notAuthorized(underlying).errorDescription)

        #expect(described.contains("insufficient authentication scopes"))
        // And says what to do about it, since the API's own wording does not.
        #expect(described.contains("Signing out and back in"))
    }

    /// Creating the space is what needs this scope, and nothing else in the app does — so
    /// dropping it from the list would leave every other feature working and only this one
    /// failing, at the moment someone clicks the button.
    @Test func signInAsksForTheMeetingScope() {
        #expect(
            OAuthConfiguration.scopes
                .contains("https://www.googleapis.com/auth/meetings.space.created")
        )
    }

    // MARK: - What gets posted

    private let link = URL(string: "https://meet.google.com/abc-mnop-xyz")!

    /// The common case: the button clicked with nothing typed. Bare URL, no prose around
    /// it — Chat annotates it into a joinable chip itself.
    @Test func linkAloneWhenNothingWasTyped() {
        #expect(MeetInvitation.messageText(joinURL: link) == "https://meet.google.com/abc-mnop-xyz")
    }

    @Test func draftIsSentAboveTheLink() {
        let text = MeetInvitation.messageText(joinURL: link, comment: "Standup now?")
        #expect(text == "Standup now?\nhttps://meet.google.com/abc-mnop-xyz")
    }

    /// A field holding only whitespace — a stray space, a newline left behind — is an empty
    /// draft, not a blank first line above the link.
    @Test func blankDraftIsNotAnEmptyLine() {
        #expect(MeetInvitation.messageText(joinURL: link, comment: "  \n ") == link.absoluteString)
    }

    /// The link always starts its own line. Glued to the last word it would not be a link
    /// at all: Chat's detection ends at whitespace, so the whole run would be one token.
    @Test func multiLineDraftKeepsTheLinkOnItsOwnLine() {
        let text = MeetInvitation.messageText(joinURL: link, comment: "Two things:\n- the parser")
        #expect(text.hasSuffix("\n\(link.absoluteString)"))
        #expect(text == "Two things:\n- the parser\nhttps://meet.google.com/abc-mnop-xyz")
    }
}
