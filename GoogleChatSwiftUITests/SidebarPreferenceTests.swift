import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// Pin and mute are this app's own state, with no server copy to check them
/// against — so the ordering rules are only ever as correct as these tests.
struct SidebarPreferenceTests {
    private func makeStore() throws -> (ChatStore, ModelContainer) {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (ChatStore(modelContainer: container), container)
    }

    /// Decoded rather than built with the memberwise initialiser, so these stay
    /// valid as `ChatSpace` gains fields.
    private func space(_ id: String) throws -> ChatSpace {
        try JSONDecoder().decode(
            ChatSpace.self,
            from: Data(#"{"name":"spaces/\#(id)","spaceType":"SPACE"}"#.utf8)
        )
    }

    /// Pinned names in the order the sidebar would list them.
    private func pinnedNames(in container: ModelContainer) throws -> [String] {
        let context = ModelContext(container)
        let pinned = try context.fetch(
            FetchDescriptor<CachedSpace>(predicate: #Predicate { $0.isPinned })
        )
        return pinned.sorted { $0.pinnedOrder < $1.pinnedOrder }.map(\.name)
    }

    @Test func pinningAppendsToTheEndOfTheGroup() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([space("A"), space("B"), space("C")])

        try await store.setPinned(true, for: "spaces/A")
        try await store.setPinned(true, for: "spaces/B")
        try await store.setPinned(true, for: "spaces/C")

        #expect(try pinnedNames(in: container) == ["spaces/A", "spaces/B", "spaces/C"])
    }

    @Test func unpinningLeavesTheRestInOrderAndRepinningGoesLast() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([space("A"), space("B"), space("C")])
        for id in ["A", "B", "C"] { try await store.setPinned(true, for: "spaces/\(id)") }

        try await store.setPinned(false, for: "spaces/A")
        #expect(try pinnedNames(in: container) == ["spaces/B", "spaces/C"])

        // The re-pinned space must not reclaim its old index — index 0 was reset on
        // unpin, and reusing it would put it back above rows it no longer outranks.
        try await store.setPinned(true, for: "spaces/A")
        #expect(try pinnedNames(in: container) == ["spaces/B", "spaces/C", "spaces/A"])
    }

    @Test func reorderingRewritesTheWholeArrangement() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([space("A"), space("B"), space("C")])
        for id in ["A", "B", "C"] { try await store.setPinned(true, for: "spaces/\(id)") }

        // What a drag of the last row to the top produces.
        try await store.reorderPinned(["spaces/C", "spaces/A", "spaces/B"])

        #expect(try pinnedNames(in: container) == ["spaces/C", "spaces/A", "spaces/B"])
    }

    /// A space pinned while the sidebar was filtered is absent from the list the
    /// view hands back. It must keep its pin and sort after the named rows rather
    /// than falling to index 0 and jumping to the top.
    @Test func reorderingKeepsPinnedSpacesItWasNotToldAbout() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([space("A"), space("B"), space("C")])
        for id in ["A", "B", "C"] { try await store.setPinned(true, for: "spaces/\(id)") }

        try await store.reorderPinned(["spaces/B", "spaces/A"])

        #expect(try pinnedNames(in: container) == ["spaces/B", "spaces/A", "spaces/C"])
    }

    private func setUnread(_ count: Int, for name: String, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let match = try context.fetch(
            FetchDescriptor<CachedSpace>(predicate: #Predicate { $0.name == name })
        )
        match.first?.unreadCount = count
        try context.save()
    }

    @Test func mutedSpacesAreLeftOutOfTheUnreadTotal() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([space("A"), space("B")])
        try setUnread(3, for: "spaces/A", in: container)
        try setUnread(4, for: "spaces/B", in: container)

        #expect(try await store.totalUnread() == 7)

        try await store.setMuted(true, for: "spaces/B")
        #expect(try await store.totalUnread() == 3)
        #expect(try await store.isMuted(spaceName: "spaces/B"))
    }
}
