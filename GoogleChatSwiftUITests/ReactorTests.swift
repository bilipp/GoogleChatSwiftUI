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
}
