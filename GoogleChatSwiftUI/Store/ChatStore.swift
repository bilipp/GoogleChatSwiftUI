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

    /// Caches directory lookups so names survive relaunch and are shared by the
    /// sidebar and the transcript.
    func upsertPeople(_ people: [DirectoryPerson]) throws {
        guard !people.isEmpty else { return }
        let names = Set(people.map(\.chatUserName))
        let existing = try modelContext.fetch(
            FetchDescriptor<CachedUser>(predicate: #Predicate { names.contains($0.name) })
        )
        var byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })

        for person in people {
            let target: CachedUser
            if let found = byName[person.chatUserName] {
                target = found
            } else {
                let created = CachedUser(name: person.chatUserName)
                modelContext.insert(created)
                byName[person.chatUserName] = created
                target = created
            }
            target.displayName = person.displayName
            target.photoURL = person.photoURL
        }
        try modelContext.save()
    }

    /// Which of these Chat user IDs have no cached directory profile yet.
    func unknownUserIDs(_ ids: [String]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        let known = try modelContext.fetch(
            FetchDescriptor<CachedUser>(predicate: #Predicate { wanted.contains($0.name) })
        )
        var alreadyNamed: Set<String> = []
        for user in known where user.displayName != nil {
            alreadyNamed.insert(user.name)
        }
        return Array(wanted.subtracting(alreadyNamed))
    }

    /// Cached display names for the given Chat user IDs.
    func displayNames(for ids: [String]) throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        let users = try modelContext.fetch(
            FetchDescriptor<CachedUser>(predicate: #Predicate { wanted.contains($0.name) })
        )
        var result: [String: String] = [:]
        for user in users {
            if let displayName = user.displayName { result[user.name] = displayName }
        }
        return result
    }

    func setResolvedTitle(_ title: String?, peers: [String] = [], for spaceName: String) throws {
        guard let space = try space(named: spaceName) else { return }
        space.resolvedTitle = title
        space.peerUserIDs = peers
        // Marked resolved even on failure, so an unnameable space is not retried
        // on every launch forever.
        space.didResolveTitle = true
        try modelContext.save()
    }

    // MARK: - Sections and mute state

    /// Assigns spaces to navigation sections.
    ///
    /// Spaces absent from the mapping are cleared rather than left alone: a space moved
    /// out of a custom section would otherwise keep showing under it forever.
    func applySections(
        _ sections: [ChatSection],
        items: [ChatSectionItem]
    ) throws -> Int {
        var byName: [String: ChatSection] = [:]
        for section in sections {
            if let name = section.name { byName[name] = section }
        }

        var sectionForSpace: [String: ChatSection] = [:]
        for item in items {
            guard let space = item.space,
                  let sectionName = item.sectionName,
                  let section = byName[sectionName]
            else { continue }
            sectionForSpace[space] = section
        }

        let all = try modelContext.fetch(FetchDescriptor<CachedSpace>())
        for space in all {
            let section = sectionForSpace[space.name]
            space.sectionName = section?.name
            space.sectionTitle = section?.title
            space.sectionSortOrder = section?.sortOrder ?? 0
        }

        try modelContext.save()
        return sectionForSpace.count
    }

    /// Spaces still needing a notification-setting lookup, most active first.
    ///
    /// Bounded the same way as read state: one call per space, and mute state on a
    /// conversation nobody has touched in months is not worth a request.
    func spacesNeedingNotificationSetting(limit: Int, activeSince: Date) throws -> [String] {
        var descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { space in
                !space.didFetchNotificationSetting && space.lastActiveTime != nil
            },
            sortBy: [SortDescriptor(\.lastActiveTime, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
            .filter { ($0.lastActiveTime ?? .distantPast) >= activeSince }
            .map(\.name)
    }

    func applyNotificationSetting(_ setting: String?, for spaceName: String) throws {
        guard let space = try space(named: spaceName) else { return }
        space.notificationSettingRaw = setting
        // Marked fetched even on failure, so an unreadable space is not retried
        // on every pass forever.
        space.didFetchNotificationSetting = true
        try modelContext.save()
    }

    // MARK: - Search index

    /// Fills `searchableText` for rows cached before the column existed.
    ///
    /// Purely local — no network — so it can run in full on launch. Without it,
    /// search would silently miss every message already in the cache, and would only
    /// improve as spaces happened to be reopened.
    /// - Returns: how many rows were indexed.
    ///
    /// Deliberately fetches every message rather than predicating on an empty index.
    /// A non-optional column added by lightweight migration is NULL in pre-existing
    /// rows, not `""`, so `searchableText.isEmpty` matched nothing and the first
    /// version of this silently indexed zero messages. Comparing against the freshly
    /// computed value also self-heals if the index formula ever changes.
    @discardableResult
    func backfillSearchIndex() throws -> Int {
        let all = try modelContext.fetch(FetchDescriptor<CachedMessage>())
        var indexed = 0

        for message in all {
            let expected = CachedMessage.searchIndex(
                text: message.text,
                fallback: message.fallbackText
            )
            guard !expected.isEmpty, message.searchableText != expected else { continue }
            message.searchableText = expected
            indexed += 1
        }

        if indexed > 0 { try modelContext.save() }
        return indexed
    }

    // MARK: - Read state

    /// Spaces worth checking read state for, most recently active first.
    ///
    /// Bounded and activity-ordered: read state is one call per space, and checking
    /// all 762 on every launch would cost more than the badges are worth. Dormant
    /// spaces are almost never unread anyway.
    func spacesNeedingReadState(limit: Int, activeSince: Date) throws -> [String] {
        var descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { space in
                !space.didFetchReadState && space.lastActiveTime != nil
            },
            sortBy: [SortDescriptor(\.lastActiveTime, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
            .filter { ($0.lastActiveTime ?? .distantPast) >= activeSince }
            .map(\.name)
    }

    func applyReadState(_ lastReadTime: Date?, for spaceName: String) throws {
        guard let space = try space(named: spaceName) else { return }
        space.lastReadTime = lastReadTime
        space.didFetchReadState = true
        space.unreadCount = Self.countUnread(in: space, after: lastReadTime)
        try modelContext.save()
    }

    /// Counts cached messages newer than the read mark, excluding tombstones.
    ///
    /// This is a floor, not a truth: a space whose history has not been backfilled
    /// reports zero even when unread. `hasUnread` covers that case from timestamps
    /// alone, so the badge shows a dot rather than a wrong number.
    private static func countUnread(in space: CachedSpace, after mark: Date?) -> Int {
        guard let mark else { return 0 }
        return space.messages.count { message in
            guard let created = message.createTime, !message.isDeleted else { return false }
            return created > mark
        }
    }

    /// Clears unread locally after the server has accepted a read update.
    func markReadLocally(spaceName: String, at time: Date) throws {
        guard let space = try space(named: spaceName) else { return }
        space.lastReadTime = time
        space.didFetchReadState = true
        space.unreadCount = 0
        try modelContext.save()
    }

    /// Bumps the unread counter for a message that arrived while elsewhere.
    ///
    /// - Returns: the space's display title when the message counted as unread, nil
    ///   when it did not. The title comes back with the verdict because the caller
    ///   needs it to announce the message and has no other route into the cache.
    func noteIncomingMessage(
        _ message: ChatMessage,
        in spaceName: String,
        selfChatName: String?
    ) throws -> String? {
        guard let space = try space(named: spaceName) else { return nil }
        // Your own messages are never unread, and neither is anything at or before
        // the read mark — realtime can redeliver.
        guard message.sender?.name != selfChatName else { return nil }
        guard let created = message.createTime else { return nil }
        if let mark = space.lastReadTime, created <= mark { return nil }

        space.unreadCount += 1
        try modelContext.save()
        return space.title
    }

    func unreadSpaceNames() throws -> [String] {
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { $0.unreadCount > 0 }
        )
        return try modelContext.fetch(descriptor).map(\.name)
    }

    /// Total unread across every space, for the menu bar.
    func totalUnread() throws -> Int {
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { $0.unreadCount > 0 }
        )
        return try modelContext.fetch(descriptor).reduce(0) { $0 + $1.unreadCount }
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

    /// Mirrors a message's reaction summaries into cached rows.
    ///
    /// `myReactionName` is preserved across refreshes: the server summary never says
    /// whether you reacted, so re-applying it would wipe knowledge we paid an extra
    /// call to obtain.
    private func syncReactions(of remote: ChatMessage, on cached: CachedMessage) {
        let summaries = remote.emojiReactionSummaries ?? []
        var existing = Dictionary(
            cached.reactions.map { ($0.emoji, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for summary in summaries {
            guard let emoji = summary.emoji?.display else { continue }
            let count = summary.reactionCount ?? 0
            if let row = existing.removeValue(forKey: emoji) {
                row.count = count
            } else {
                let row = CachedReaction(
                    key: "\(cached.name)|\(emoji)",
                    emoji: emoji,
                    count: count
                )
                row.message = cached
                modelContext.insert(row)
            }
        }

        // Anything left is a reaction that was fully removed server-side.
        for (_, stale) in existing {
            modelContext.delete(stale)
        }
    }

    private func syncAttachments(of remote: ChatMessage, on cached: CachedMessage) {
        let incoming = remote.attachment ?? []
        guard !incoming.isEmpty || !cached.attachments.isEmpty else { return }

        var existing = Dictionary(
            cached.attachments.compactMap { row -> (String, CachedAttachment)? in (row.name, row) },
            uniquingKeysWith: { first, _ in first }
        )

        for attachment in incoming {
            guard let name = attachment.name else { continue }
            let row = existing.removeValue(forKey: name) ?? {
                let created = CachedAttachment(name: name)
                created.message = cached
                modelContext.insert(created)
                return created
            }()
            row.contentName = attachment.contentName
            row.contentType = attachment.contentType
            row.thumbnailURI = attachment.thumbnailUri
            row.downloadURI = attachment.downloadUri
            row.dataResourceName = attachment.attachmentDataRef?.resourceName
        }

        for (_, stale) in existing {
            modelContext.delete(stale)
        }
    }

    /// Records the signed-in user's own reaction so it can be toggled off later.
    func setMyReaction(_ reactionName: String?, emoji: String, on messageName: String) throws {
        let key = "\(messageName)|\(emoji)"
        var descriptor = FetchDescriptor<CachedReaction>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1

        if let row = try modelContext.fetch(descriptor).first {
            row.myReactionName = reactionName
            // Optimistic count nudge; the next refresh replaces it with the truth.
            row.count = max(0, row.count + (reactionName == nil ? -1 : 1))
            if row.count == 0 && reactionName == nil {
                modelContext.delete(row)
            }
        } else if reactionName != nil, let message = try message(named: messageName) {
            let row = CachedReaction(key: key, emoji: emoji, count: 1)
            row.myReactionName = reactionName
            row.message = message
            modelContext.insert(row)
        }
        try modelContext.save()
    }

    /// Applies a full reaction listing, which is the only way to learn which
    /// reactions are the signed-in user's own.
    func applyReactionListing(
        _ reactions: [ChatReaction],
        for messageName: String,
        selfChatName: String?
    ) throws {
        guard let message = try message(named: messageName) else { return }

        var counts: [String: Int] = [:]
        var mine: [String: String] = [:]

        for reaction in reactions {
            guard let emoji = reaction.emoji?.display else { continue }
            counts[emoji, default: 0] += 1
            if let selfChatName, reaction.user?.name == selfChatName, let name = reaction.name {
                mine[emoji] = name
            }
        }

        for row in message.reactions {
            modelContext.delete(row)
        }
        for (emoji, count) in counts {
            let row = CachedReaction(key: "\(messageName)|\(emoji)", emoji: emoji, count: count)
            row.myReactionName = mine[emoji]
            row.message = message
            modelContext.insert(row)
        }
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
            let target: CachedMessage
            if let found = byName[message.name] {
                found.apply(message)
                target = found
            } else {
                let created = CachedMessage(name: message.name)
                created.apply(message)
                created.space = space
                modelContext.insert(created)
                byName[message.name] = created
                target = created
            }
            syncReactions(of: message, on: target)
            syncAttachments(of: message, on: target)
        }

        // The sidebar sorts and scopes on `lastActiveTime`, and Chat only revises it
        // on the space record — which the event stream never delivers. Without this a
        // message arriving live leaves its conversation sitting wherever it was, and a
        // space quiet for a month stays hidden behind the "Recent" filter entirely.
        //
        // Advanced rather than assigned: backfilling old history and merging an edit
        // both pass through here, and neither is new activity.
        if let newest = messages.compactMap(\.createTime).max(),
           newest > (space.lastActiveTime ?? .distantPast) {
            space.lastActiveTime = newest
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
