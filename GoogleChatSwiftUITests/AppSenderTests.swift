import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// Naming the senders of webhook messages.
///
/// The bug these exist for: every message posted by a Chat app or an incoming webhook
/// read "Unknown" over a blank avatar. That is not a rendering slip but the end of a
/// chain — Chat returns a sender's ID and type and no `displayName` under user
/// authentication, the app resolved names through the People API, and People has no
/// entry for an app to return. So an app sender fell down the same hole as a colleague
/// whose lookup had not landed, and stayed there: the lookup was retried on every sync
/// pass and could never succeed.
///
/// What the rules have to get right is the distinction the old code could not express:
/// unnamed-and-unnameable is not the same state as not-named-yet.
struct AppSenderTests {
    private func makeStore() throws -> (ChatStore, ModelContainer) {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (ChatStore(modelContainer: container), container)
    }

    private func space() throws -> ChatSpace {
        let json = #"{"name":"spaces/A","spaceType":"SPACE"}"#
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    /// Decoded rather than built by hand, so these carry exactly what Chat sends — which
    /// is the whole point here: a `sender` with a name and a type and nothing else.
    private func message(
        _ id: String,
        sender: String = "users/webhook",
        type: String? = "BOT"
    ) throws -> ChatMessage {
        let senderJSON = type.map { #"{"name":"\#(sender)","type":"\#($0)"}"# }
            ?? #"{"name":"\#(sender)"}"#
        let json = """
        {
          "name":"spaces/A/messages/\(id)",
          "text":"*New user created:*",
          "createTime":"2026-08-07T19:04:15Z",
          "sender":\(senderJSON)
        }
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func cached(_ name: String, in container: ModelContainer) throws -> CachedMessage? {
        try ModelContext(container).fetch(
            FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.name == name })
        ).first
    }

    private func user(_ name: String, in container: ModelContainer) throws -> CachedUser? {
        try ModelContext(container).fetch(
            FetchDescriptor<CachedUser>(predicate: #Predicate { $0.name == name })
        ).first
    }

    // MARK: - Keeping the type Chat does send

    /// The one identity field the API fills in, and the app used to drop it.
    @Test func recordsThatAnAppPostedAMessage() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.mergeMessages([try message("m1")], into: "spaces/A")

        let row = try #require(try cached("spaces/A/messages/m1", in: container))
        #expect(row.senderTypeRaw == "BOT")
        #expect(row.isAppSender)
    }

    @Test func doesNotTakeAPersonForAnApp() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.mergeMessages(
            [try message("m1", sender: "users/1", type: "HUMAN")],
            into: "spaces/A"
        )

        let row = try #require(try cached("spaces/A/messages/m1", in: container))
        #expect(!row.isAppSender)
    }

    /// A payload that omits the type must not un-say what an earlier one established.
    @Test func keepsTheTypeThroughAResponseThatOmitsIt() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.mergeMessages([try message("m1")], into: "spaces/A")
        try await store.mergeMessages([try message("m1", type: nil)], into: "spaces/A")

        let row = try #require(try cached("spaces/A/messages/m1", in: container))
        #expect(row.isAppSender)
    }

    // MARK: - What the transcript shows

    @Test func namesAnUnnamedAppAsAnApp() throws {
        let identity = SenderIdentity(resolvedName: nil, isApp: true)
        #expect(identity.name == "App")
        // The avatar takes no initial from a placeholder — "A" for "App" would be an
        // invented one.
        #expect(identity.resolvedName == nil)
    }

    /// The distinction the fix turns on: a person with no name yet is a lookup in
    /// flight, and still reads "Unknown".
    @Test func stillSaysUnknownForAPersonTheDirectoryHasNotNamed() throws {
        #expect(SenderIdentity(resolvedName: nil, isApp: false).name == "Unknown")
    }

    @Test func prefersTheNameSomebodyTyped() throws {
        let identity = SenderIdentity(resolvedName: "Service", isApp: true)
        #expect(identity.name == "Service")
    }

    /// The reason app-ness is stored on the sender and not only on the message: history
    /// cached before the app kept sender types has no type on it, and re-fetching every
    /// space to fill that in is not something this app does.
    /// On the main actor because reading a model to build an identity is: see the
    /// extension on ``SenderIdentity``.
    @MainActor
    @Test func treatsOlderMessagesFromAKnownAppAsApps() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.mergeMessages([try message("m1", type: nil)], into: "spaces/A")
        try await store.markAppUsers(["users/webhook"])

        let row = try #require(try cached("spaces/A/messages/m1", in: container))
        let sender = try #require(try user("users/webhook", in: container))
        #expect(!row.isAppSender)

        let identity = SenderIdentity(message: row, sender: sender)
        #expect(identity.isApp)
        #expect(identity.name == "App")
    }

    // MARK: - Not asking People about apps

    /// The quota half of the bug. An app can never be resolved, so leaving it in the
    /// unknown set bought a batch lookup — and a 404 — on every space open, forever.
    @Test func stopsAskingTheDirectoryAboutApps() async throws {
        let (store, _) = try makeStore()
        try await store.markAppUsers(["users/webhook"])

        let unknown = try await store.unknownUserIDs(["users/webhook", "users/1"])
        #expect(unknown == ["users/1"])
    }

    @Test func marksAnAppOnceAndLeavesItAlone() async throws {
        let (store, container) = try makeStore()
        try await store.markAppUsers(["users/webhook"])
        try await store.setLocalName("Service", for: "users/webhook")
        try await store.markAppUsers(["users/webhook"])

        let sender = try #require(try user("users/webhook", in: container))
        #expect(sender.isApp)
        #expect(sender.displayName == "Service")
    }

    // MARK: - The name the user supplies

    @Test func namesAnAppFromTheUser() async throws {
        let (store, container) = try makeStore()
        try await store.markAppUsers(["users/webhook"])
        try await store.setLocalName("  Service  ", for: "users/webhook")

        let sender = try #require(try user("users/webhook", in: container))
        #expect(sender.displayName == "Service")
        #expect(sender.isLocallyNamed)
    }

    /// Emptying the field is the only way back to the placeholder.
    @Test func clearsANameAgain() async throws {
        let (store, container) = try makeStore()
        try await store.setLocalName("Service", for: "users/webhook")
        try await store.setLocalName("   ", for: "users/webhook")

        let sender = try #require(try user("users/webhook", in: container))
        #expect(sender.displayName == nil)
        #expect(!sender.isLocallyNamed)
    }

    /// A directory pass must not overwrite a name it could not have produced. Apps are
    /// the case that matters, but the rule is the safe one for anybody: the typed name is
    /// the only one there was a reason to type.
    @Test func keepsATypedNameThroughADirectoryPass() async throws {
        let (store, container) = try makeStore()
        try await store.setLocalName("Service", for: "users/webhook")
        try await store.upsertPeople([
            DirectoryPerson(
                chatUserName: "users/webhook",
                displayName: "Some Directory Answer",
                photoURL: "https://example.com/photo.jpg"
            )
        ])

        let sender = try #require(try user("users/webhook", in: container))
        #expect(sender.displayName == "Service")
        // The photo is still taken: it is not in competition with anything typed.
        #expect(sender.photoURL == "https://example.com/photo.jpg")
    }
}
