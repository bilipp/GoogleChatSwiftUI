import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// SwiftData logs persistent history on every save whether or not anything reads it, and
/// nothing prunes it by itself. Left alone it had grown to 37,577 transactions and 77,219
/// changes here — roughly 6MB of a 32MB cache, spread across five indexes on the
/// transaction table, all of them written to on every save.
///
/// The prune is best-effort and its failure is logged rather than surfaced, which is
/// exactly the shape of change that can quietly stop working. So this checks it runs: a
/// store that has been written to, pruned, and is still readable afterwards.
struct HistoryPruneTests {
    /// File-backed, not in-memory: history tracking is a property of a real store, so an
    /// in-memory container would prove nothing about the call that matters.
    private func makeStore() throws -> (ChatStore, ModelContainer, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "test.store")
        let container = try ModelContainer(
            for: Schema(versionedSchema: ChatSchemaV1.self),
            configurations: ModelConfiguration(url: url)
        )
        return (ChatStore(modelContainer: container), container, dir)
    }

    private func space(_ id: String) throws -> ChatSpace {
        try GoogleTransport.decoder.decode(
            ChatSpace.self,
            from: Data(#"{"name":"spaces/\#(id)","spaceType":"SPACE"}"#.utf8)
        )
    }

    @Test func pruningLeavesTheCacheReadable() async throws {
        let (store, container, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Enough saves to put something in the log.
        for index in 0..<20 {
            try await store.upsertSpaces([try space("S\(index)")])
        }

        try await store.pruneHistory()

        // The rows the history described are still there — a prune of the log must never
        // be a prune of the data.
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<CachedSpace>()) == 20)

        // And the store still takes writes afterwards.
        try await store.upsertSpaces([try space("S20")])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<CachedSpace>()) == 21)
    }

    /// The cutoff is what keeps the recent end of the log intact, so a prune "now" must
    /// not be a prune of everything: it is dated, and the date is in the past.
    @Test func theRetentionWindowIsInThePast() {
        #expect(ChatStore.historyRetention > 0)
        let cutoff = Date().addingTimeInterval(-ChatStore.historyRetention)
        #expect(cutoff < Date())
    }
}
