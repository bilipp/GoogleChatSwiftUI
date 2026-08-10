import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// Opening the chat with a person clicked in a space or a thread.
///
/// The two halves worth pinning down are the two that fail silently. The cache lookup
/// is what keeps the common case off the network — a wrong answer there is not an
/// error, it is a request nobody asked for and, in the miss direction, a *created*
/// conversation where an existing one should have been found. And the setup body is a
/// wire shape Chat validates and this app never sees again.
struct DirectMessageTests {
    private func makeStore() throws -> (ChatStore, ModelContainer) {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (ChatStore(modelContainer: container), container)
    }

    /// Decoded rather than built with the memberwise initialiser, so these stay valid
    /// as the DTOs gain fields.
    private func space(_ id: String, type: String) throws -> ChatSpace {
        let json = #"{"name":"spaces/\#(id)","spaceType":"\#(type)"}"#
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    @Test("A cached DM is found by its peer")
    func findsCachedDirectMessage() async throws {
        let (store, _) = try makeStore()
        try await store.upsertSpaces([
            try space("DM", type: "DIRECT_MESSAGE"),
            try space("ROOM", type: "SPACE"),
        ])
        try await store.setResolvedTitle("Ada Lovelace", peers: ["users/ada"], for: "spaces/DM")

        #expect(try await store.directMessageSpaceName(with: "users/ada") == "spaces/DM")
    }

    /// The miss that matters: answering with a space or a group chat would open the
    /// wrong conversation, and answering with nothing when a DM exists would create a
    /// second one.
    @Test("Only one-to-one conversations answer")
    func ignoresGroupsAndSpaces() async throws {
        let (store, _) = try makeStore()
        try await store.upsertSpaces([
            try space("ROOM", type: "SPACE"),
            try space("GROUP", type: "GROUP_CHAT"),
        ])
        try await store.setResolvedTitle("Ada, Ben", peers: ["users/ada", "users/ben"], for: "spaces/GROUP")
        try await store.setResolvedTitle("Engineering", peers: ["users/ada"], for: "spaces/ROOM")

        #expect(try await store.directMessageSpaceName(with: "users/ada") == nil)
    }

    /// The bug this feature shipped with, and the reason `spaceType` cannot be trusted
    /// to mean "two people": Chat labels plenty of conversations `DIRECT_MESSAGE` that
    /// hold three or more. Clicking Ada in one of those opened the group rather than the
    /// chat with her, because both spaces list her as a member.
    @Test("A group conversation typed as a DM does not answer for its members")
    func ignoresMultiPersonDirectMessages() async throws {
        let (store, _) = try makeStore()
        try await store.upsertSpaces([
            try space("GROUPISH", type: "DIRECT_MESSAGE"),
            try space("DM", type: "DIRECT_MESSAGE"),
        ])
        // Ordered so the wrong answer is the one the fetch reaches first.
        try await store.setResolvedTitle(
            "Ada Lovelace, Ben Green",
            peers: ["users/ada", "users/ben"],
            for: "spaces/GROUPISH"
        )
        try await store.setResolvedTitle("Ada Lovelace", peers: ["users/ada"], for: "spaces/DM")

        #expect(try await store.directMessageSpaceName(with: "users/ada") == "spaces/DM")
        // And with no one-to-one cached for Ben, the group is still not the answer —
        // the caller falls through to `findDirectMessage` rather than opening it.
        #expect(try await store.directMessageSpaceName(with: "users/ben") == nil)
    }

    /// A DM whose members have not been resolved yet has no peers stored, so the cache
    /// cannot speak for it — the caller has to fall through to `findDirectMessage`
    /// rather than treat this as "no conversation exists".
    @Test("An unresolved DM is not an answer")
    func unresolvedDirectMessageIsAMiss() async throws {
        let (store, _) = try makeStore()
        try await store.upsertSpaces([try space("DM", type: "DIRECT_MESSAGE")])

        #expect(try await store.directMessageSpaceName(with: "users/ada") == nil)
    }

    /// The shape `spaces.setup` requires: the space says what kind of conversation it
    /// is, and the single membership says who the other side is. Chat rejects the call
    /// outright if the member has no type, which is exactly the kind of omission a
    /// hand-built body invites.
    @Test("Setting up a DM sends the membership Chat requires")
    func setUpBodyNamesOneHumanMember() throws {
        let encoded = try JSONEncoder().encode(SetUpDirectMessageBody(user: "users/ada"))
        let object = try JSONSerialization.jsonObject(with: encoded)
        let json = try #require(object as? [String: Any])

        let space = try #require(json["space"] as? [String: Any])
        #expect(space["spaceType"] as? String == "DIRECT_MESSAGE")

        let memberships = try #require(json["memberships"] as? [[String: Any]])
        #expect(memberships.count == 1)
        let member = try #require(memberships.first?["member"] as? [String: Any])
        #expect(member["name"] as? String == "users/ada")
        #expect(member["type"] as? String == "HUMAN")
    }
}
