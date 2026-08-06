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
            let target: CachedSpace
            if let found = byName[space.name] {
                found.apply(space)
                target = found
            } else {
                let created = CachedSpace(name: space.name)
                created.apply(space)
                modelContext.insert(created)
                byName[space.name] = created
                target = created
            }

            // A space Chat already names needs no members lookup. Marking it resolved
            // here keeps it out of the pending-title query entirely.
            if let name = target.displayName, !name.isEmpty {
                target.didResolveTitle = true
            }
        }

        try modelContext.save()
        logger.info("Upserted \(remote.count) spaces")
    }

    /// Space names that still need a members lookup to be nameable, newest first.
    ///
    /// The predicate filters in the store rather than fetching a page and filtering
    /// in memory: an in-memory filter would only ever see the most-recently-active
    /// slice, leaving every older DM permanently unnamed and search useless.
    func spacesNeedingTitles(limit: Int) throws -> [String] {
        let directMessage = ChatSpace.SpaceType.directMessage.rawValue
        let groupChat = ChatSpace.SpaceType.groupChat.rawValue

        // Kept to two clauses: adding the displayName check inline exceeds the type
        // checker's budget. Spaces that already have a name are marked resolved at
        // upsert instead, so they never reach this query.
        var descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { space in
                !space.didResolveTitle
                    && (space.spaceTypeRaw == directMessage || space.spaceTypeRaw == groupChat)
            },
            sortBy: [SortDescriptor(\.lastActiveTime, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.name)
    }

    func setResolvedTitle(_ title: String?, for spaceName: String) throws {
        guard let space = try space(named: spaceName) else { return }
        space.resolvedTitle = title
        // Marked resolved even on failure, so an unnameable space is not retried
        // on every launch forever.
        space.didResolveTitle = true
        try modelContext.save()
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

    // MARK: - Optimistic writes

    /// Inserts a locally-composed message so it renders immediately.
    ///
    /// The placeholder is keyed by the same client-assigned ID used as the API's
    /// idempotency key, so when the server echoes the message back it lands on this
    /// row instead of creating a duplicate.
    func insertPendingMessage(
        clientID: String,
        text: String,
        spaceName: String,
        senderName: String?,
        senderDisplayName: String?,
        threadName: String?
    ) throws {
        guard let space = try space(named: spaceName) else { return }

        let placeholder = CachedMessage(name: "\(spaceName)/messages/\(clientID)")
        placeholder.text = text
        placeholder.createTime = Date()
        placeholder.senderName = senderName
        placeholder.senderDisplayName = senderDisplayName
        placeholder.threadName = threadName
        placeholder.isThreadReply = threadName != nil
        placeholder.isPending = true
        placeholder.space = space

        modelContext.insert(placeholder)
        try modelContext.save()
    }

    /// Replaces the placeholder with the server's version of the message.
    func confirmPendingMessage(clientID: String, spaceName: String, server: ChatMessage) throws {
        guard let space = try space(named: spaceName) else { return }
        let placeholderName = "\(spaceName)/messages/\(clientID)"

        if let existing = try message(named: placeholderName) {
            // The server assigns the canonical resource name, which usually differs
            // from the client-assigned one. Delete and re-insert rather than mutating
            // a @Attribute(.unique) primary key in place.
            modelContext.delete(existing)
        }

        try upsert([server], into: space)
        if let confirmed = try message(named: server.name) {
            confirmed.isPending = false
            confirmed.sendFailureReason = nil
        }
        try modelContext.save()
    }

    /// Marks a placeholder as failed so the UI can offer a retry.
    func markSendFailed(clientID: String, spaceName: String, reason: String) throws {
        let name = "\(spaceName)/messages/\(clientID)"
        guard let placeholder = try message(named: name) else { return }
        placeholder.isPending = false
        placeholder.sendFailureReason = reason
        try modelContext.save()
    }

    func discardMessage(named name: String) throws {
        guard let message = try message(named: name) else { return }
        modelContext.delete(message)
        try modelContext.save()
    }

    /// Applies an edit locally after the server has accepted it.
    func applyEdit(to name: String, text: String) throws {
        guard let message = try message(named: name) else { return }
        message.text = text
        message.lastUpdateTime = Date()
        try modelContext.save()
    }

    /// Tombstones a message locally. Chat keeps deleted messages visible as
    /// "Message deleted", so the row stays rather than vanishing.
    func applyDeletion(to name: String) throws {
        guard let message = try message(named: name) else { return }
        message.deleteTime = Date()
        message.text = nil
        try modelContext.save()
    }

    // MARK: - Queries

    func message(named name: String) throws -> CachedMessage? {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.name == name }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

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
