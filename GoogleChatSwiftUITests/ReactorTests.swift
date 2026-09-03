import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// Naming the people behind a reaction chip.
///
/// Chat reports reactions as counts — "👍 4" — and never says who. The names come from
/// a separate listing call whose entries carry user IDs, which then go through the same
/// People lookup message senders do. Two things decide whether the resulting list is
/// worth showing: the order, which the listing itself does not supply, and what happens
/// to someone the directory cannot name, who must still be counted.
struct ReactorTests {
    private func makeStore() throws -> (ChatStore, ModelContainer) {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (ChatStore(modelContainer: container), container)
    }

    private func reactor(
        _ id: String,
        named displayName: String?,
        isSelf: Bool = false,
        isApp: Bool = false
    ) -> Reactor {
        Reactor(
            userID: id,
            displayName: displayName,
            photoURL: nil,
            isApp: isApp,
            isSelf: isSelf
        )
    }

    // MARK: - Ordering

    @Test func theSignedInUserIsListedFirstHoweverTheyAreNamed() {
        let ordered = Reactor.ordered([
            reactor("users/1", named: "Ana"),
            reactor("users/me", named: "Zoe", isSelf: true),
            reactor("users/2", named: "Ben"),
        ])

        #expect(ordered.map(\.userID) == ["users/me", "users/1", "users/2"])
        #expect(ordered.first?.label == "You")
    }

    @Test func everyoneElseIsAlphabeticalRegardlessOfTheOrderChatReturned() {
        let ordered = Reactor.ordered([
            reactor("users/3", named: "chen"),
            reactor("users/1", named: "Ana"),
            reactor("users/2", named: "ben"),
        ])

        #expect(ordered.map(\.displayName) == ["Ana", "ben", "chen"])
    }

    /// The name is what a reader scans, so a row with none belongs at the bottom rather
    /// than filed under whatever its placeholder happens to start with.
    @Test func peopleTheDirectoryCouldNotNameSortLastButAreStillListed() {
        let ordered = Reactor.ordered([
            reactor("users/9", named: nil),
            reactor("users/1", named: "Ana"),
            reactor("users/2", named: "Zoe"),
        ])

        #expect(ordered.map(\.label) == ["Ana", "Zoe", "Unknown user"])
    }

    /// Two colleagues can share a name; the list must not reshuffle them between opens.
    @Test func sameNamedPeopleKeepAFixedOrder() {
        let first = Reactor.ordered([
            reactor("users/2", named: "Ana"),
            reactor("users/1", named: "Ana"),
        ])
        let second = Reactor.ordered([
            reactor("users/1", named: "Ana"),
            reactor("users/2", named: "Ana"),
        ])

        #expect(first.map(\.userID) == second.map(\.userID))
    }

    // MARK: - Profiles

    /// The list draws a face as well as a name, and both come out of the same cached row
    /// the transcript reads — one lookup per person, not one per surface.
    @Test func cachedProfilesCarryTheNameAndThePhoto() async throws {
        let (store, _) = try makeStore()
        try await store.upsertPeople([
            DirectoryPerson(
                chatUserName: "users/1",
                displayName: "Ana Ruiz",
                photoURL: "https://example.com/ana.jpg"
            )
        ])

        let profiles = try await store.profiles(for: ["users/1", "users/2"])

        #expect(profiles["users/1"]?.displayName == "Ana Ruiz")
        #expect(profiles["users/1"]?.photoURL == "https://example.com/ana.jpg")
        // Absent rather than blank: an ID with no row is one the caller still has to
        // decide how to draw.
        #expect(profiles["users/2"] == nil)
    }

    /// An app can react, and People has no entry for one — so the row exists carrying a
    /// type and no name, and the list has to survive that rather than skip it.
    @Test func anAppReactorIsMarkedAsOne() async throws {
        let (store, _) = try makeStore()
        try await store.markAppUsers(["users/webhook"])

        let profiles = try await store.profiles(for: ["users/webhook"])

        #expect(profiles["users/webhook"]?.isApp == true)
        #expect(profiles["users/webhook"]?.displayName == nil)
    }

    // MARK: - Replacing a listing

    /// A full listing replaces the cached rows outright, and the rows it replaces are
    /// found by fetch rather than through `message.reactions`.
    ///
    /// Worth a test of its own because that fetch is a `#Predicate` over a relationship,
    /// and a predicate SwiftData cannot translate does not fail to compile — it throws
    /// when it runs, or answers nothing and silently leaves the stale rows behind.
    @Test func aFullListingReplacesTheCachedReactions() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.mergeMessages([try message()], into: "spaces/A")

        // A first listing, then a second that drops one emoji and adds another.
        try await store.applyReactionListing(
            [try reaction("r1", emoji: "👍", by: "users/1"), try reaction("r2", emoji: "🎉", by: "users/2")],
            for: "spaces/A/messages/m1",
            selfChatName: "users/1"
        )
        try await store.applyReactionListing(
            [try reaction("r3", emoji: "🎉", by: "users/2"), try reaction("r4", emoji: "🚀", by: "users/1")],
            for: "spaces/A/messages/m1",
            selfChatName: "users/1"
        )

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<CachedReaction>())
        #expect(rows.map(\.emoji).sorted() == ["🎉", "🚀"])
        // The signed-in user's own reaction moved with the listing — the one thing the
        // summary endpoint never reports, and so the reason this call exists.
        #expect(rows.first { $0.emoji == "🚀" }?.myReactionName == "spaces/A/messages/m1/reactions/r4")
        #expect(rows.first { $0.emoji == "🎉" }?.myReactionName == nil)
    }

    private func space() throws -> ChatSpace {
        let json = #"{"name":"spaces/A","spaceType":"SPACE"}"#
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    private func message() throws -> ChatMessage {
        let json = """
        {"name":"spaces/A/messages/m1","text":"hi","createTime":"2026-07-01T10:00:00Z",
         "sender":{"name":"users/1"}}
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func reaction(_ id: String, emoji: String, by userID: String) throws -> ChatReaction {
        let json = """
        {"name":"spaces/A/messages/m1/reactions/\(id)",
         "user":{"name":"\(userID)"},
         "emoji":{"unicode":"\(emoji)"}}
        """
        return try GoogleTransport.decoder.decode(ChatReaction.self, from: Data(json.utf8))
    }
}
