import Foundation
import OSLog
import SwiftData

/// Background writer for the SwiftData cache.
///
/// All mutation happens here, off the main actor, so a 762-space upsert or a long
/// history backfill never blocks the UI. Views read through `@Query` on the main
/// context instead of going through this actor.
@ModelActor
actor ChatStore {
    private var logger: Logger { Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "store") }

    // MARK: - Spaces

    /// Upserts the space list. Existing rows keep their backfill cursors — this must
    /// not reset sync progress just because the space list was refreshed.
    func upsertSpaces(_ remote: [ChatSpace]) throws {
        let existing = try modelContext.fetch(FetchDescriptor<CachedSpace>())
        var byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })

        for space in remote {
            if let found = byName[space.name] {
                found.apply(space)
            } else {
                let created = CachedSpace(name: space.name)
                created.apply(space)
                modelContext.insert(created)
                byName[space.name] = created
            }
        }

        try modelContext.save()
        logger.info("Upserted \(remote.count) spaces")
    }

    // MARK: - Messages

    /// Inserts a page of history and advances the space's backfill cursor.
    ///
    /// - Parameter nextPageToken: nil or empty marks the history walk complete.
    func appendHistory(
        _ messages: [ChatMessage],
        to spaceName: String,
        nextPageToken: String?
    ) throws {
        guard let space = try space(named: spaceName) else {
            logger.error("Cannot append history: unknown space \(spaceName)")
            return
        }

        try upsert(messages, into: space)

        let token = nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        space.backfillPageToken = token
        space.backfillComplete = (token == nil)
        space.lastSyncedAt = Date()

        try modelContext.save()
    }

    /// Merges messages that arrived out of band (event stream, or a head re-fetch).
    func mergeMessages(_ messages: [ChatMessage], into spaceName: String) throws {
        guard let space = try space(named: spaceName) else { return }
        try upsert(messages, into: space)
        space.lastSyncedAt = Date()
        try modelContext.save()
    }

    /// Upsert keyed on the message resource name, which is what makes paginated
    /// backfill and the live event stream converge instead of duplicating.
    private func upsert(_ messages: [ChatMessage], into space: CachedSpace) throws {
        guard !messages.isEmpty else { return }

        let names = Set(messages.map(\.name))
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { names.contains($0.name) }
        )
        let existing = try modelContext.fetch(descriptor)
        var byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })

        for message in messages {
            if let found = byName[message.name] {
                found.apply(message)
            } else {
                let created = CachedMessage(name: message.name)
                created.apply(message)
                created.space = space
                modelContext.insert(created)
                byName[message.name] = created
            }
        }
    }

    // MARK: - Queries

    func space(named name: String) throws -> CachedSpace? {
        var descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate { $0.name == name }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Backfill state for a space: the cursor to resume from, and whether to bother.
    func backfillState(for spaceName: String) throws -> (token: String?, complete: Bool, hasMessages: Bool) {
        guard let space = try space(named: spaceName) else { return (nil, false, false) }
        return (space.backfillPageToken, space.backfillComplete, !space.messages.isEmpty)
    }
}
