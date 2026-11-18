import Foundation
import OSLog
import SwiftData

/// Where the server says the user has read to in one thread.
///
/// A named pair rather than a tuple because it crosses into the store actor, and
/// "(String, Date?)" at a call site says nothing about which end is which.
nonisolated struct ThreadReadState: Sendable {
    let threadName: String
    /// Nil where the endpoint would not answer. Recorded as checked regardless, so a
    /// thread Chat will not report on is not asked about again on every visit.
    let lastReadTime: Date?
}

/// Where the server says the user has read to in one space, for the batch that
/// ``ChatStore/applyReadStates(_:)`` writes.
nonisolated struct SpaceReadState: Sendable {
    let spaceName: String
    /// Nil where the endpoint would not answer. Recorded as fetched regardless, so a
    /// space Chat will not report on is not asked about on every pass forever.
    let lastReadTime: Date?
}

/// A name worked out for a space Chat does not name itself, for the batch that
/// ``ChatStore/setResolvedTitles(_:)`` writes.
nonisolated struct ResolvedSpaceTitle: Sendable {
    let spaceName: String
    /// Nil where no name could be produced. Still recorded, so an unnameable space is
    /// not retried forever.
    let title: String?
    let peers: [String]
}

/// A cached person, copied out of the store so it can cross back to the main actor.
///
/// `CachedUser` itself cannot: SwiftData models belong to the context that fetched
/// them, and this one was fetched on the store's.
nonisolated struct UserProfile: Sendable, Hashable {
    let name: String
    let displayName: String?
    let photoURL: String?
    let isApp: Bool
}

/// Background writer for the SwiftData cache.
///
/// All mutation happens here, off the main actor, so a 762-space upsert or a long
/// history backfill never blocks the UI. Views read through `@Query` on the main
/// context instead of going through this actor.
@ModelActor
actor ChatStore {
    private var logger: Logger { AppLog.logger("store") }

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

    /// The cached one-to-one conversation with one person, if this account has one.
    ///
    /// The peer list has to be exactly this person, and `spaceType` cannot stand in for
    /// that: Chat labels conversations `DIRECT_MESSAGE` that hold three, four, six
    /// people — this account has dozens — so "a DM containing them" also describes the
    /// group chat with them and two colleagues, and matching on that opened whichever
    /// of the two the fetch happened to return first. `peerUserIDs` is derived from the
    /// actual membership with the signed-in user removed, so a single entry is the one
    /// honest statement that a conversation is between two people.
    ///
    /// There can be more than one, and then the liveliest wins. A conversation that
    /// began as a group collapses to a single peer when everyone else leaves or has
    /// their account deleted, which leaves two conversations that are both, now,
    /// between the same two people. Neither is wrong to open — but the one still being
    /// used is the one the click means, so they are ordered by activity rather than by
    /// whatever the store hands back first.
    ///
    /// Filtered in memory rather than by predicate: `peerUserIDs` is an array attribute,
    /// and SwiftData will not translate a comparison over one. The fetch is narrowed to
    /// direct messages first, so this walks a few hundred rows at worst.
    ///
    /// Returns nil for a DM whose members have not been resolved yet, which is why the
    /// caller has an API fallback rather than treating this as the answer.
    /// - Parameter userID: Chat user resource name, e.g. `users/1234567890`.
    func directMessageSpaceName(with userID: String) throws -> String? {
        let directMessage = ChatSpace.SpaceType.directMessage.rawValue
        let spaces = try modelContext.fetch(
            FetchDescriptor<CachedSpace>(
                predicate: #Predicate<CachedSpace> { $0.spaceTypeRaw == directMessage }
            )
        )
        return spaces
            .filter { $0.peerUserIDs == [userID] }
            // Sorted here rather than by the fetch: a `SortDescriptor` over an optional
            // date leaves where the nils land to the store, and a conversation nobody
            // has ever posted in is the last one to open, not the first.
            .max { ($0.lastActiveTime ?? .distantPast) < ($1.lastActiveTime ?? .distantPast) }?
            .name
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
            // A hand-typed name is never overwritten: it exists because nothing the app
            // can ask would produce one, so a directory answer is not an improvement.
            if !target.isLocallyNamed { target.displayName = person.displayName }
            target.photoURL = person.photoURL
        }
        try modelContext.save()
        announceDirectoryChange()
    }

    /// Records that these senders are apps — Chat apps or incoming webhooks.
    ///
    /// Written from message sender types because that is the only place the information
    /// appears. Nothing else about the row is touched: an app's name can only have come
    /// from the user, and this runs on every sync pass.
    func markAppUsers(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        let existing = try modelContext.fetch(
            FetchDescriptor<CachedUser>(predicate: #Predicate { wanted.contains($0.name) })
        )
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })

        var added = 0
        for id in wanted {
            if let found = byName[id] {
                guard !found.isApp else { continue }
                found.isApp = true
            } else {
                let created = CachedUser(name: id)
                created.isApp = true
                modelContext.insert(created)
            }
            added += 1
        }
        guard added > 0 else { return }
        try modelContext.save()
        announceDirectoryChange()
        logger.info("Marked \(added) sender(s) as apps")
    }

    /// Names a sender by hand — the only way an app is ever named here.
    ///
    /// Lands in the same row the directory writes to, so one name reaches the transcript,
    /// the thread list, search and notifications at once.
    /// - Parameter displayName: nil or blank clears the name again.
    func setLocalName(_ displayName: String?, for userID: String) throws {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = try modelContext.fetch(
            FetchDescriptor<CachedUser>(predicate: #Predicate { $0.name == userID })
        ).first ?? {
            let created = CachedUser(name: userID)
            modelContext.insert(created)
            return created
        }()

        if let trimmed, !trimmed.isEmpty {
            target.displayName = trimmed
            target.isLocallyNamed = true
        } else {
            target.displayName = nil
            target.isLocallyNamed = false
        }
        try modelContext.save()
        announceDirectoryChange()
    }

    /// Which of these Chat user IDs have no cached directory profile yet.
    ///
    /// Apps are reported as known however unnamed they are: People has no entry for one,
    /// so asking again on every pass would buy a 404 per app per space opened.
    func unknownUserIDs(_ ids: [String]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        let known = try modelContext.fetch(
            FetchDescriptor<CachedUser>(predicate: #Predicate { wanted.contains($0.name) })
        )
        var alreadyNamed: Set<String> = []
        for user in known where user.displayName != nil || user.isApp {
            alreadyNamed.insert(user.name)
        }
        return Array(wanted.subtracting(alreadyNamed))
    }

    /// Every person the directory has already answered for, apps excluded.
    ///
    /// The input to ``SyncEngine/refreshDirectory()``, and the one lookup that is
    /// deliberately *not* gated on ``unknownUserIDs(_:)``. That gate asks "has this ID
    /// ever been resolved", which is the right question for naming someone and the wrong
    /// one for keeping them current: a row resolved once is never revisited, so a name
    /// that changed, or a photo that was wrong when it was written, stays wrong for as
    /// long as the cache lives. Apps are left out because People cannot answer for one.
    func personIDs() throws -> [String] {
        try modelContext
            .fetch(FetchDescriptor<CachedUser>(predicate: #Predicate { !$0.isApp }))
            .map(\.name)
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

    /// Cached profiles for the given Chat user IDs.
    ///
    /// The counterpart to ``displayNames(for:)`` for callers that draw a face as well as
    /// a name. IDs with no row are absent rather than represented by a blank profile, so
    /// the caller can decide what an unresolvable person looks like.
    func profiles(for ids: [String]) throws -> [String: UserProfile] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        let users = try modelContext.fetch(
            FetchDescriptor<CachedUser>(predicate: #Predicate { wanted.contains($0.name) })
        )
        return snapshot(of: users)
    }

    /// The whole directory, for ``DirectoryCache``.
    ///
    /// Unbounded on purpose, and affordable for the same reason the cache exists: this
    /// runs here, off the main actor, and only when the directory has actually changed.
    /// The views used to do the equivalent fetch on the main thread, five of them, on
    /// every write to the store.
    func allProfiles() throws -> [String: UserProfile] {
        snapshot(of: try modelContext.fetch(FetchDescriptor<CachedUser>()))
    }

    private func snapshot(of users: [CachedUser]) -> [String: UserProfile] {
        Dictionary(
            uniqueKeysWithValues: users.map {
                ($0.name, UserProfile(name: $0.name, displayName: $0.displayName,
                                      photoURL: $0.photoURL, isApp: $0.isApp))
            }
        )
    }

    /// Tells ``DirectoryCache`` its snapshot is out of date.
    ///
    /// Called beside every save that touches a `CachedUser`, which is what keeps a new
    /// directory writer from silently leaving the cache stale.
    private func announceDirectoryChange() {
        NotificationCenter.default.post(name: .chatDirectoryChanged, object: nil)
    }

    /// One space's resolved title. See ``setResolvedTitles(_:)``, which this defers to —
    /// a pass over many spaces must not take one save each.
    func setResolvedTitle(_ title: String?, peers: [String] = [], for spaceName: String) throws {
        try setResolvedTitles(
            [ResolvedSpaceTitle(spaceName: spaceName, title: title, peers: peers)]
        )
    }

    /// Writes a whole pass of resolved titles under one save.
    ///
    /// One save, not one per space, and that is the point of the plural. `@Query`
    /// refetches on every write to the store, and the views watching it hold several
    /// unbounded fetches between them — so a save is not a cheap thing to do 25 times
    /// in a row, which is what a per-space write here amounted to. See
    /// ``SyncEngine/resolvePendingTitles(excludingUser:)`` for the pass this serves.
    func setResolvedTitles(_ titles: [ResolvedSpaceTitle]) throws {
        guard !titles.isEmpty else { return }
        let wanted = Set(titles.map(\.spaceName))
        let spaces = try modelContext.fetch(
            FetchDescriptor<CachedSpace>(predicate: #Predicate { wanted.contains($0.name) })
        )
        let byName = Dictionary(uniqueKeysWithValues: spaces.map { ($0.name, $0) })

        for resolved in titles {
            guard let space = byName[resolved.spaceName] else { continue }
            space.resolvedTitle = resolved.title
            space.peerUserIDs = resolved.peers
            // Marked resolved even on failure, so an unnameable space is not retried
            // on every launch forever.
            space.didResolveTitle = true
        }
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

    /// Local pin state. Chat has no equivalent, so this never leaves the device.
    func setPinned(_ pinned: Bool, for spaceName: String) throws {
        guard let space = try space(named: spaceName) else { return }
        space.isPinned = pinned
        // New pins land at the end of the group; unpinning resets the index so a
        // later re-pin does the same rather than reappearing at a position nobody
        // remembers choosing.
        space.pinnedOrder = pinned ? try nextPinnedOrder() : 0
        try modelContext.save()
    }

    private func nextPinnedOrder() throws -> Int {
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { $0.isPinned }
        )
        let highest = try modelContext.fetch(descriptor).map(\.pinnedOrder).max()
        return (highest ?? -1) + 1
    }

    /// Rewrites the pinned group's order from a full list of space names, in the
    /// order they should appear.
    ///
    /// Takes the whole arrangement rather than a from/to pair: the caller already
    /// holds the reordered list, and reindexing all of it leaves no gaps or ties to
    /// reason about later.
    func reorderPinned(_ spaceNames: [String]) throws {
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { $0.isPinned }
        )
        let pinned = try modelContext.fetch(descriptor)
        var positions: [String: Int] = [:]
        for (index, name) in spaceNames.enumerated() { positions[name] = index }

        for space in pinned {
            // A pinned space missing from the list sorts after everything named in
            // it, rather than silently jumping to the top on a zero default.
            space.pinnedOrder = positions[space.name] ?? spaceNames.count
        }
        try modelContext.save()
    }

    /// Records a mute state, whether read from Chat or just set here.
    func setMuted(_ muted: Bool, for spaceName: String) throws {
        guard let space = try space(named: spaceName) else { return }
        space.isMuted = muted
        space.muteSettingFetchedAt = .now
        try modelContext.save()
    }

    /// Spaces whose mute state has never been read, or not since `staleBefore`, most
    /// recently active first. Bounded the way ``spacesNeedingReadState(limit:activeSince:)``
    /// is: one call per space, and dormant spaces rarely matter.
    func spacesNeedingMuteSetting(limit: Int, activeSince: Date, staleBefore: Date) throws -> [String] {
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { $0.lastActiveTime != nil },
            sortBy: [SortDescriptor(\.lastActiveTime, order: .reverse)]
        )
        var names: [String] = []
        for space in try modelContext.fetch(descriptor) {
            guard let active = space.lastActiveTime, active >= activeSince else { break }
            if let fetched = space.muteSettingFetchedAt, fetched >= staleBefore { continue }
            names.append(space.name)
            if names.count == limit { break }
        }
        return names
    }

    /// Writes a pass of mute states under one save, for the reason
    /// ``applyReadStates(_:)`` does. Returns the spaces whose state changed.
    @discardableResult
    func applyMuteSettings(_ settings: [String: Bool]) throws -> [String] {
        guard !settings.isEmpty else { return [] }
        let wanted = Set(settings.keys)
        let spaces = try modelContext.fetch(
            FetchDescriptor<CachedSpace>(predicate: #Predicate { wanted.contains($0.name) })
        )
        let now = Date.now
        var changed: [String] = []
        for space in spaces {
            guard let muted = settings[space.name] else { continue }
            if space.isMuted != muted {
                space.isMuted = muted
                changed.append(space.name)
            }
            space.muteSettingFetchedAt = now
        }
        try modelContext.save()
        return changed
    }

    func isMuted(spaceName: String) throws -> Bool {
        try space(named: spaceName)?.isMuted ?? false
    }

    // MARK: - History

    /// How long the persistent-history log is kept.
    ///
    /// Long enough to be obviously safe, short enough that the log stops growing. Nothing
    /// in this app reads history at all — cross-context change propagation inside a
    /// process does not go through it — so the only reason for a window rather than
    /// "everything" is that the store's own machinery is entitled to the recent end of it.
    static let historyRetention: TimeInterval = 24 * 60 * 60

    /// Drops history older than ``historyRetention``.
    ///
    /// SwiftData tracks persistent history whether or not anyone reads it, and nothing
    /// prunes it by itself. This store had 37,577 transactions and 77,219 changes logged
    /// over three weeks — roughly 6MB of a 32MB cache, spread over five indexes on the
    /// transaction table, every one of them written to on every save. That is pure
    /// overhead on the writes the sync engine makes constantly, and it grows without
    /// bound.
    func pruneHistory(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-Self.historyRetention)
        try modelContext.deleteHistory(
            HistoryDescriptor<DefaultHistoryTransaction>(
                predicate: #Predicate { $0.timestamp < cutoff }
            )
        )
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
            // The forwarded body has to be passed here as well as at merge time. This pass
            // rewrites any row whose index differs from what the formula now produces —
            // which is what makes it self-healing, and what would silently strip a forward's
            // text back out again on the next launch if the two calls disagreed.
            let expected = CachedMessage.searchIndex(
                text: message.text,
                fallback: message.fallbackText,
                forwarded: message.isForwarded ? message.quotedMessageText : nil
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

    /// One space's read state. See ``applyReadStates(_:)``, which this defers to.
    func applyReadState(_ lastReadTime: Date?, for spaceName: String) throws {
        try applyReadStates(
            [SpaceReadState(spaceName: spaceName, lastReadTime: lastReadTime)]
        )
    }

    /// Writes a whole pass of read states under one save.
    ///
    /// One save for the batch rather than one per space, for the reason
    /// ``setResolvedTitles(_:)`` takes a list: every write to the store makes each `@Query`
    /// on the main context refetch, and a pass of 25 spaces was therefore 25 rounds of
    /// that. The recounts stay per space — they are reads, and each one needs its own
    /// space row — but they now happen inside a single transaction.
    func applyReadStates(_ states: [SpaceReadState]) throws {
        guard !states.isEmpty else { return }
        let wanted = Set(states.map(\.spaceName))
        let spaces = try modelContext.fetch(
            FetchDescriptor<CachedSpace>(predicate: #Predicate { wanted.contains($0.name) })
        )
        let byName = Dictionary(uniqueKeysWithValues: spaces.map { ($0.name, $0) })

        for state in states {
            guard let space = byName[state.spaceName] else { continue }
            space.lastReadTime = state.lastReadTime
            space.didFetchReadState = true
            space.unreadCount = try countUnread(
                in: state.spaceName, after: state.lastReadTime
            )
            // Threads cached before this arrived had nothing to measure against. This is
            // the first moment they can be told where the user had got to, which is why
            // the mark is passed to the recount rather than seeded in a pass of its own.
            try recountThreadTotals(in: space, seedingAt: state.lastReadTime)
        }
        try modelContext.save()
    }

    /// Counts cached messages newer than the read mark, excluding tombstones.
    ///
    /// This is a floor, not a truth: a space whose history has not been backfilled
    /// reports zero even when unread. `hasUnread` covers that case from timestamps
    /// alone, so the badge shows a dot rather than a wrong number.
    /// Counted in SQLite rather than by walking `space.messages`, which materialized
    /// every cached message in the room — 4,685 of them in the busiest space here — to
    /// arrive at one number.
    ///
    /// The optional timestamp is compared through `flatMap` for the reason
    /// ``TranscriptQueries/messages(in:after:)`` is: SwiftData rejects a force-unwrap
    /// inside `#Predicate`, and `??` on anything but an optional `Bool` is not an
    /// expression it accepts.
    private func countUnread(in spaceName: String, after mark: Date?) throws -> Int {
        guard let mark else { return 0 }
        return try modelContext.fetchCount(
            FetchDescriptor<CachedMessage>(
                predicate: #Predicate<CachedMessage> { message in
                    message.space?.name == spaceName
                        && message.deleteTime == nil
                        && (message.createTime.flatMap { $0 > mark } ?? false)
                }
            )
        )
    }

    /// Clears unread locally after the server has accepted a read update.
    ///
    /// Deliberately does *not* touch threads that already have a read mark. Reading
    /// the room is not reading its threads — their replies were never on screen — and
    /// clearing them here is exactly the behaviour that made an unread reply
    /// impossible to find. Threads with no mark yet are seeded, since for those this
    /// timestamp is the best evidence available.
    func markReadLocally(spaceName: String, at time: Date) throws {
        guard let space = try space(named: spaceName) else { return }
        space.lastReadTime = time
        space.didFetchReadState = true
        space.unreadCount = 0
        try recountThreadTotals(in: space, seedingAt: time)
        try modelContext.save()
    }

    /// How far back the read mark goes to make a space unread again.
    ///
    /// A whole second rather than the smallest representable step because the mark is
    /// sent to Chat as ISO-8601 with second precision: a sub-second nudge would be
    /// truncated back onto the message's own timestamp, and a mark equal to the newest
    /// message is a space that is read.
    private static let unreadMarkGap: TimeInterval = -1

    /// Where the read mark has to sit for this space to count as unread again.
    ///
    /// Anchored on the newest message in the cache, so the space comes back with
    /// exactly one thing to read — the message the user is coming back for — rather
    /// than resurrecting history they have already read. A space with nothing cached
    /// falls back to its last activity, which gives the sidebar a dot instead of a
    /// count, the same way an unbackfilled space already behaves.
    ///
    /// - Returns: nil when the space is unknown or has never had any activity, since
    ///   there is then nothing to be unread about.
    func unreadMark(spaceName: String) throws -> Date? {
        guard let space = try space(named: spaceName) else { return nil }
        // One row, ordered by the fetch. Filtering `space.messages` in memory pulled every
        // cached message in the room across to find the largest timestamp among them.
        // A message still in flight is not something to come back and read.
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate<CachedMessage> { message in
                message.space?.name == spaceName
                    && (message.deleteTime == nil && !message.isPending)
            },
            sortBy: [SortDescriptor(\CachedMessage.createTime, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let newest = try modelContext.fetch(descriptor).first?.createTime
        guard let anchor = newest ?? space.lastActiveTime else { return nil }
        return anchor.addingTimeInterval(Self.unreadMarkGap)
    }

    /// Puts the read mark back after the server has accepted it, the mirror of
    /// `markReadLocally`.
    ///
    /// Threads are deliberately untouched, for the same reason opening a space leaves
    /// them alone: their replies are read on their own marks, and Chat's space read
    /// state does not speak for them either. The thread tallies are still recomputed,
    /// because moving the space mark changes which unread replies the space's own count
    /// already covers — leave them and the badge double-counts.
    func markUnreadLocally(spaceName: String, at time: Date) throws {
        guard let space = try space(named: spaceName) else { return }
        space.lastReadTime = time
        space.didFetchReadState = true
        space.unreadCount = try countUnread(in: spaceName, after: time)
        try recountThreadTotals(in: space)
        try modelContext.save()
    }

    // MARK: - Thread read state

    /// Advances a thread's read mark, which is what opening it means.
    /// - Returns: the mark it replaced, so the pane can still draw a line at the
    ///   point the user had read to — the thing they opened it to find.
    @discardableResult
    func markThreadRead(threadName: String, at time: Date = Date()) throws -> Date? {
        guard let thread = try thread(named: threadName) else { return nil }
        let previous = thread.didSeedReadState ? thread.lastReadTime : nil
        thread.lastReadTime = time
        thread.didSeedReadState = true
        if let space = thread.space { try refreshThreadState(of: thread, in: space) }
        try modelContext.save()
        return previous
    }

    /// Puts a thread's read mark just before its newest reply, so that reply — and only
    /// that one — reads as new again.
    /// - Returns: the mark it set, for the caller to send to the server, or nil when
    ///   the thread has no reply to be unread about.
    func markThreadUnread(threadName: String) throws -> Date? {
        guard let thread = try thread(named: threadName),
              let newest = thread.lastReplyTime
        else { return nil }
        let mark = newest.addingTimeInterval(Self.unreadMarkGap)
        thread.lastReadTime = mark
        thread.didSeedReadState = true
        // A mark set here is newer news than whatever the server said before it.
        thread.didCheckServerReadState = true
        if let space = thread.space { try refreshThreadState(of: thread, in: space) }
        try modelContext.save()
        return mark
    }

    /// Threads in a space with unread replies — the ones "mark all read" has to report
    /// to the server. The rest are already read there or were never unread here.
    func unreadThreadNames(spaceName: String) throws -> [String] {
        let descriptor = FetchDescriptor<CachedThread>(
            predicate: #Predicate<CachedThread> { thread in
                thread.space?.name == spaceName && thread.unreadReplyCount > 0
            }
        )
        return try modelContext.fetch(descriptor).map(\.name)
    }

    /// Clears every thread in a space at once, for "mark all as read".
    ///
    /// The only operation here that genuinely has to write to every thread in the room —
    /// but it needs no message access to do it. Each mark moves to `time`, and every
    /// cached reply is older than that, so every thread ends with nothing unread and
    /// nothing hidden. Asking the messages would be asking a question whose answer is
    /// already known.
    ///
    /// `replyCount` and the activity timestamps are left alone deliberately: they describe
    /// the thread's contents, not the user's position in it, and reading a room does not
    /// change what is in it.
    func markAllThreadsRead(spaceName: String, at time: Date = Date()) throws {
        guard let space = try space(named: spaceName) else { return }
        for thread in try threads(inSpace: spaceName) {
            thread.lastReadTime = time
            thread.didSeedReadState = true
            thread.unreadReplyCount = 0
            thread.hiddenUnreadReplyCount = 0
        }
        space.unreadThreadCount = 0
        space.unreadThreadReplyCount = 0
        space.threadTallyVersion = Self.threadTallyVersion
        try modelContext.save()
    }

    /// Applies the server's view of where the user has read to in a thread.
    ///
    /// Forward-only. Chat reports a thread never explicitly opened as read at the
    /// epoch, and letting that overwrite a mark seeded from the space would resurrect
    /// every reply in the cache as unread.
    func applyThreadReadState(_ serverTime: Date?, for threadName: String) throws {
        try applyThreadReadStates([ThreadReadState(threadName: threadName, lastReadTime: serverTime)])
    }

    /// The same, for a batch of threads answered together.
    ///
    /// A batch rather than a loop over the single-thread call: the marks all land first,
    /// and the tallies they invalidate are recomputed once afterwards, so a thread named
    /// twice in one batch is not counted twice. The answers arrive twenty-five at a time,
    /// which is what makes the batching worth having.
    ///
    /// - Parameter authoritative: true for a read-state *event*, which reports a change
    ///   the user made elsewhere — including marking a thread unread, which moves the
    ///   mark backwards. The polled check stays forward-only, because what it reads for
    ///   a thread never opened anywhere is the epoch, not a decision.
    func applyThreadReadStates(_ states: [ThreadReadState], authoritative: Bool = false) throws {
        guard !states.isEmpty else { return }
        // Keyed by thread name so a name repeated in one batch is recomputed once.
        var touched: [String: CachedThread] = [:]

        for state in states {
            guard let thread = try thread(named: state.threadName) else { continue }
            thread.didCheckServerReadState = true
            guard let serverTime = state.lastReadTime,
                  serverTime != thread.lastReadTime,
                  authoritative || serverTime > (thread.lastReadTime ?? .distantPast)
            else { continue }
            thread.lastReadTime = serverTime
            thread.didSeedReadState = true
            touched[thread.name] = thread
        }

        // Then by space, which is the unit the tallies are kept in — one adjustment per
        // space rather than one per thread.
        let bySpace = Dictionary(grouping: touched.values) { $0.space?.name ?? "" }
        for threads in bySpace.values {
            guard let space = threads.first?.space else { continue }
            try refreshThreadState(of: threads, in: space)
        }
        try modelContext.save()
    }

    /// Unread threads whose read mark has not yet been checked against the server,
    /// newest first — the only ones where the check can change anything.
    ///
    /// Narrowed, ordered and limited by the fetch. Reading `space.threads` and doing all
    /// three in memory materialized every thread in the room to return at most
    /// twenty-five names — 0.79s in the busiest space here, on the path a conversation
    /// opens by.
    func threadsNeedingServerReadState(spaceName: String, limit: Int) throws -> [String] {
        var descriptor = FetchDescriptor<CachedThread>(
            predicate: #Predicate<CachedThread> { thread in
                thread.space?.name == spaceName
                    && (thread.unreadReplyCount > 0 && !thread.didCheckServerReadState)
            },
            sortBy: [SortDescriptor(\CachedThread.lastReplyTime, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.name)
    }

    func spacesWithUnreadThreads() throws -> [String] {
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { $0.unreadThreadCount > 0 }
        )
        return try modelContext.fetch(descriptor).map(\.name)
    }

    /// Which version of the tally rules this build computes. See
    /// ``CachedSpace/threadTallyVersion`` — bump this whenever anything in
    /// ``recomputeTallies(of:spaceMark:messages:)`` changes what it counts.
    static let threadTallyVersion = 1

    /// Recomputes one thread's tallies, and stores its contribution to the space's.
    ///
    /// The inner loop is the original whole-space pass, narrowed to a single thread.
    /// Nothing about it depends on the other threads in the space, which is the fact
    /// the incremental path below is built on.
    /// - Parameter messages: the thread's messages, from the caller's bulk fetch. Required
    ///   rather than defaulting to `thread.messages`, and that is the point: faulting the
    ///   relationship here was both a SQLite round trip per thread and a deferred to-many
    ///   fault per thread, and the latter is what crashed build 21 against a main context
    ///   faulting a relationship of its own. Every caller now goes through
    ///   ``messagesByThread(named:)``, so there is no path left that faults.
    private static func recomputeTallies(
        of thread: CachedThread,
        spaceMark: Date,
        messages: [CachedMessage]
    ) {
        let mark = thread.lastReadTime ?? .distantPast
        var replies = 0
        var newestReply: Date?
        var newestActivity: Date?
        var unread = 0
        var hidden = 0
        // The two columns the thread list reads instead of walking `messages` — see
        // ``CachedThread/rootMessageName``. Tracked here because this is already the one
        // pass over a thread's messages, so they cost nothing to carry.
        var root: CachedMessage?
        var newestReplyName: String?

        for message in messages {
            let created = message.createTime ?? .distantPast

            // Before the deleted guard: `root` has never excluded deleted messages, and
            // must not start to — a thread whose opening message was deleted still shows
            // "Message deleted" as its snippet rather than losing its starter entirely.
            if isRoot(message, betterThan: root) { root = message }

            guard !message.isDeleted else { continue }
            if created > (newestActivity ?? .distantPast) { newestActivity = created }
            guard message.isThreadReply else { continue }

            replies += 1
            if created > (newestReply ?? .distantPast) {
                newestReply = created
                newestReplyName = message.name
            }
            guard thread.didSeedReadState, created > mark else { continue }
            unread += 1
            // Replies at or before the space's own mark are invisible to
            // `unreadCount`, so only those are the badge's to add.
            if created <= spaceMark { hidden += 1 }
        }

        thread.replyCount = replies
        thread.lastReplyTime = newestReply
        thread.lastActivityTime = newestActivity
        thread.unreadReplyCount = unread
        thread.hiddenUnreadReplyCount = hidden
        thread.rootMessageName = root?.name
        thread.lastReplyMessageName = newestReplyName
    }

    /// Whether `candidate` is a better answer for the thread's root than `incumbent`.
    ///
    /// Mirrors ``CachedThread/root``: a non-reply beats a reply, and among equals the
    /// earliest wins. The relationship's own `first` is used there for want of an order —
    /// a to-many relationship has none — so this is the same rule made deterministic
    /// rather than a different one.
    private static func isRoot(_ candidate: CachedMessage, betterThan incumbent: CachedMessage?) -> Bool {
        guard let incumbent else { return true }
        if candidate.isThreadReply != incumbent.isThreadReply { return !candidate.isThreadReply }
        return (candidate.createTime ?? .distantPast) < (incumbent.createTime ?? .distantPast)
    }

    /// Recomputes every thread tally in a space, and the space's own thread totals.
    ///
    /// The honest, expensive answer, and the only one that is correct when the *space's*
    /// read mark moves: `spaceMark` is an input to every thread's hidden count, so
    /// moving it invalidates all of them at once. Keep this for those cases, and for the
    /// recount that brings a space computed by older rules up to date.
    ///
    /// Reserved for ``backfillThreads()``, which is the one caller that genuinely has to
    /// compute every thread's reply count from nothing. Everything else recounts through
    /// ``recountThreadTotals(in:seedingAt:)``, which reaches the same totals by touching
    /// only the threads that can contribute to them.
    ///
    /// The messages arrive in a single fetch rather than a fault per thread. Faulting
    /// `thread.messages` in a loop is what made this cost 668ms for 5,106 threads in the
    /// busiest space here — one SQLite round trip per thread — against 489ms for one
    /// fetch of the same rows, and the gap widens as the room grows.
    private func refreshThreadState(in space: CachedSpace) throws {
        let spaceName = space.name
        let messages = try modelContext.fetch(
            FetchDescriptor<CachedMessage>(
                predicate: #Predicate<CachedMessage> { $0.space?.name == spaceName }
            )
        )
        var byThread: [String: [CachedMessage]] = [:]
        for message in messages {
            guard let threadName = message.threadName else { continue }
            byThread[threadName, default: []].append(message)
        }

        var unreadThreads = 0
        var hiddenUnreadReplies = 0
        let spaceMark = space.lastReadTime ?? .distantPast

        for thread in try threads(inSpace: spaceName) {
            Self.recomputeTallies(
                of: thread,
                spaceMark: spaceMark,
                messages: byThread[thread.name] ?? []
            )
            if thread.unreadReplyCount > 0 { unreadThreads += 1 }
            hiddenUnreadReplies += thread.hiddenUnreadReplyCount
        }

        space.unreadThreadCount = unreadThreads
        space.unreadThreadReplyCount = hiddenUnreadReplies
        space.threadTallyVersion = Self.threadTallyVersion
    }

    /// Recomputes the named threads only, and moves the space's totals by the
    /// difference.
    ///
    /// For everything that changes one thread, or a handful: a reply arriving, a thread
    /// being opened, a message being deleted, a send being confirmed. Each thread's
    /// tallies depend only on its own messages and its own mark, so recomputing the ones
    /// that changed and adjusting the space totals by what they used to contribute gives
    /// the same answer as the full walk for a fraction of the work — bounded by the
    /// threads touched rather than by the size of the room.
    ///
    /// Falls back to a recount when the space's totals were computed by older rules,
    /// since a delta is only meaningful against a total that agrees with it. That is what
    /// keeps this from drifting: the one way an incremental counter goes wrong is being
    /// added to a number that came from somewhere else.
    private func refreshThreadState(
        of threads: some Collection<CachedThread>,
        in space: CachedSpace
    ) throws {
        guard space.threadTallyVersion == Self.threadTallyVersion else {
            try recountThreadTotals(in: space)
            return
        }
        guard !threads.isEmpty else { return }

        let spaceMark = space.lastReadTime ?? .distantPast
        let byThread = try messagesByThread(named: threads.map(\.name))
        var unreadThreadDelta = 0
        var hiddenDelta = 0

        for thread in threads {
            let wasUnread = thread.unreadReplyCount > 0
            let wasHidden = thread.hiddenUnreadReplyCount
            Self.recomputeTallies(
                of: thread,
                spaceMark: spaceMark,
                messages: byThread[thread.name] ?? []
            )
            unreadThreadDelta += (thread.unreadReplyCount > 0 ? 1 : 0) - (wasUnread ? 1 : 0)
            hiddenDelta += thread.hiddenUnreadReplyCount - wasHidden
        }

        // Clamped rather than trusted. A delta is arithmetic over a stored number, and a
        // negative badge is a worse failure than a stale one.
        space.unreadThreadCount = max(0, space.unreadThreadCount + unreadThreadDelta)
        space.unreadThreadReplyCount = max(0, space.unreadThreadReplyCount + hiddenDelta)
    }

    /// The single-thread form, which is what most callers have.
    private func refreshThreadState(of thread: CachedThread, in space: CachedSpace) throws {
        try refreshThreadState(of: CollectionOfOne(thread), in: space)
    }

    /// Threads that a move of the *space's* read mark can affect — far fewer than all of
    /// them, and the reason opening a busy conversation no longer costs seconds.
    ///
    /// A thread's own tallies are a function of its own mark and its own messages, and a
    /// space-level mark is neither. The single quantity that does depend on it is
    /// `hiddenUnreadReplyCount`, the unread replies at or before the space's mark — and
    /// hidden is by definition a subset of unread, so a thread with nothing unread has
    /// nothing that can change. Threads with no mark of their own join them, because this
    /// is the moment they get one.
    ///
    /// Two clauses plus the relationship traversal is as much as SwiftData's predicate
    /// solver will take here, which is why the fetch looks like this rather than reading
    /// `space.threads` and filtering.
    private func threadsAffectedBySpaceMark(in spaceName: String) throws -> [CachedThread] {
        try modelContext.fetch(
            FetchDescriptor<CachedThread>(
                predicate: #Predicate<CachedThread> { thread in
                    thread.space?.name == spaceName
                        && (thread.unreadReplyCount > 0 || !thread.didSeedReadState)
                }
            )
        )
    }

    /// Recomputes a space's thread totals, and the tallies of the threads that feed them.
    ///
    /// Exact rather than approximate, and the argument matters because it is the whole
    /// saving. Both totals are sums over threads with unread replies —
    /// `unreadThreadCount` counts them, and `unreadThreadReplyCount` adds up a quantity
    /// that is zero wherever unread is zero — so a set that contains every thread with
    /// unread replies is enough to rebuild both from scratch. A thread left out had
    /// nothing unread and no mark to move, so it still has nothing unread, and it
    /// contributes zero to a sum computed from nothing.
    ///
    /// - Parameter seedingAt: the mark to give threads that have none, when the space's
    ///   own mark has just moved. Nil leaves them unseeded, which is what a recount that
    ///   is not itself a read-state change wants.
    private func recountThreadTotals(
        in space: CachedSpace,
        seedingAt seed: Date??  = nil
    ) throws {
        let affected = try threadsAffectedBySpaceMark(in: space.name)

        if let seed {
            for thread in affected where !thread.didSeedReadState {
                thread.lastReadTime = seed
                thread.didSeedReadState = true
            }
        }

        let spaceMark = space.lastReadTime ?? .distantPast
        let byThread = try messagesByThread(named: affected.map(\.name))
        var unreadThreads = 0
        var hiddenUnreadReplies = 0
        for thread in affected {
            Self.recomputeTallies(
                of: thread,
                spaceMark: spaceMark,
                messages: byThread[thread.name] ?? []
            )
            if thread.unreadReplyCount > 0 { unreadThreads += 1 }
            hiddenUnreadReplies += thread.hiddenUnreadReplyCount
        }

        space.unreadThreadCount = unreadThreads
        space.unreadThreadReplyCount = hiddenUnreadReplies
        space.threadTallyVersion = Self.threadTallyVersion
    }

    /// Merges a message that arrived over the event stream and counts it as unread where
    /// it is one, under a single save.
    ///
    /// This used to be ``mergeMessages(_:into:)`` followed by a second call that bumped
    /// the unread counter — two saves per event. A save is the expensive unit here: every
    /// `@Query` on the main context refetches on each one, so the sidebar, the transcript
    /// and the thread inspector were all redrawn twice for every message that arrived, and
    /// at several events a minute that was a redraw of the whole window every few seconds.
    ///
    /// - Returns: the space's display title when the message counted as unread, nil when
    ///   it did not. The title comes back with the verdict because the caller needs it to
    ///   announce the message and has no other route into the cache.
    func mergeIncomingMessage(
        _ message: ChatMessage,
        into spaceName: String,
        selfChatName: String?
    ) throws -> String? {
        guard let space = try space(named: spaceName) else { return nil }
        try upsert([message], into: space)
        space.lastSyncedAt = Date()

        let isUnread = Self.countsAsUnread(message, in: space, selfChatName: selfChatName)
        if isUnread { space.unreadCount += 1 }
        try modelContext.save()
        return isUnread ? space.title : nil
    }

    /// Whether an arriving message is one the reader has not seen.
    ///
    /// Your own messages are never unread, and neither is anything at or before the read
    /// mark — realtime can redeliver.
    private static func countsAsUnread(
        _ message: ChatMessage,
        in space: CachedSpace,
        selfChatName: String?
    ) -> Bool {
        guard message.sender?.name != selfChatName else { return false }
        guard let created = message.createTime else { return false }
        if let mark = space.lastReadTime, created <= mark { return false }
        return true
    }

    func unreadSpaceNames() throws -> [String] {
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { $0.unreadCount > 0 }
        )
        return try modelContext.fetch(descriptor).map(\.name)
    }

    /// Total unread across every unmuted space, for the Dock badge and menu bar.
    ///
    /// Muted conversations are excluded so the badge agrees with the notifications:
    /// silencing a space and then watching it drive the Dock count would defeat the
    /// point of silencing it.
    func totalUnread() throws -> Int {
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { space in
                !space.isMuted && (space.unreadCount > 0 || space.unreadThreadReplyCount > 0)
            }
        )
        return try modelContext.fetch(descriptor).reduce(0) { $0 + $1.totalUnread }
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

        for row in try modelContext.fetch(
            FetchDescriptor<CachedReaction>(
                predicate: #Predicate<CachedReaction> { $0.message?.name == messageName }
            )
        ) {
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
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { names.contains($0.name) }
        )
        // `syncReactions` and `syncAttachments` read both relationships on every message
        // below. Prefetched, that is one batched fault for the page; left deferred it was
        // two per message, each one a lock-free read of the store's row cache while the
        // main context was writing to it — see the build 21 crash.
        descriptor.relationshipKeyPathsForPrefetching = [\.reactions, \.attachments]
        let existing = try modelContext.fetch(descriptor)
        var byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })
        // Only the threads this batch names, fetched by name. Seeded from `space.threads`
        // this faulted every thread in the room — 2,555 of them in the busiest space
        // here — on every merge, the single-message merge an arriving event performs
        // included.
        var threadsByName = try threads(named: Set(messages.compactMap(\.thread?.name)))
        var touchedThreads: [String: CachedThread] = [:]

        for message in messages {
            let target: CachedMessage
            if let found = byName[message.name] {
                found.apply(message)
                target = found
            } else {
                let created = CachedMessage(name: message.name)
                created.apply(message)
                // Cheap only because `CachedSpace` has no `messages` collection for this
                // to be the inverse of. With one, SwiftData materialized every message in
                // the space to append this one — 25,610 model objects per arriving event
                // in the busiest room here, and the heaviest stack in every CPU diagnostic
                // macOS wrote for the app. See the note in ``CachedSpace``.
                created.space = space
                modelContext.insert(created)
                byName[message.name] = created
                target = created
            }
            if space.isThreaded, let threadName = target.threadName {
                let row = thread(named: threadName, in: space, cache: &threadsByName)
                target.thread = row
                touchedThreads[threadName] = row
            }
            syncReactions(of: message, on: target)
            syncAttachments(of: message, on: target)
        }

        // Only the threads this batch put a message into can have changed tallies, which
        // is what keeps an arriving message off the whole-space walk.
        if space.isThreaded {
            try refreshThreadState(of: touchedThreads.values, in: space)
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

    /// The index rows for a set of thread names, keyed by name — the cache
    /// ``thread(named:in:cache:)`` is seeded with.
    ///
    /// A fetch by name rather than a walk of `space.threads`, which is the difference
    /// between reading the handful of threads a merge touches and faulting every thread
    /// in the room. Names are globally unique (`spaces/AAAA/threads/BBBB`), so no space
    /// clause is needed to make this exact.
    private func threads(named names: Set<String>) throws -> [String: CachedThread] {
        guard !names.isEmpty else { return [:] }
        let found = try modelContext.fetch(
            FetchDescriptor<CachedThread>(predicate: #Predicate { names.contains($0.name) })
        )
        return Dictionary(found.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every thread row in a space.
    ///
    /// A fetch rather than `space.threads`. The relationship gives the same rows, but it
    /// gives them as a deferred to-many fault — the read that crashed build 21 when the
    /// main context happened to be faulting a relationship of its own against the same
    /// store cache. One fetch is one trip through the SQL queue instead.
    private func threads(inSpace spaceName: String) throws -> [CachedThread] {
        try modelContext.fetch(
            FetchDescriptor<CachedThread>(
                predicate: #Predicate<CachedThread> { $0.space?.name == spaceName }
            )
        )
    }

    /// The messages of the named threads, grouped by thread name.
    ///
    /// The bulk form of `thread.messages`, and the reason ``recomputeTallies(of:spaceMark:messages:)``
    /// takes its messages as an argument: faulting the relationship once per thread is a
    /// SQLite round trip per thread, and — the point here — a deferred to-many fault per
    /// thread. One fetch answers for the whole batch.
    ///
    /// Keyed on `threadName` rather than the relationship, which is how
    /// ``refreshThreadState(in:)`` has always grouped them.
    private func messagesByThread(named names: [String]) throws -> [String: [CachedMessage]] {
        guard !names.isEmpty else { return [:] }
        // `[String?]`, not `Set<String>`: `threadName` is optional, and SwiftData will
        // only translate `contains` where the element type matches the column exactly.
        let wanted: [String?] = names
        let messages = try modelContext.fetch(
            FetchDescriptor<CachedMessage>(
                predicate: #Predicate<CachedMessage> { wanted.contains($0.threadName) }
            )
        )
        var byThread: [String: [CachedMessage]] = [:]
        for message in messages {
            guard let threadName = message.threadName else { continue }
            byThread[threadName, default: []].append(message)
        }
        return byThread
    }

    /// Finds or creates the index row for a thread.
    ///
    /// A new thread inherits the space's read mark, so history the space already
    /// accounts for does not resurface as unread the moment threads start being
    /// tracked. A space whose read state has not landed yet leaves the mark unseeded
    /// for `applyReadState` to fill in.
    private func thread(
        named name: String,
        in space: CachedSpace,
        cache: inout [String: CachedThread]
    ) -> CachedThread {
        if let found = cache[name] { return found }

        let created = CachedThread(name: name)
        created.space = space
        if space.didFetchReadState {
            created.lastReadTime = space.lastReadTime
            created.didSeedReadState = true
        }
        modelContext.insert(created)
        cache[name] = created
        return created
    }

    /// Builds thread rows for messages cached before threads were tracked.
    ///
    /// Local only, like the search index backfill, and for the same reason: without
    /// it the thread list would describe only the handful of messages that happen to
    /// pass through a refresh, and reply counts on older threads would read low.
    /// - Returns: how many messages were linked.
    @discardableResult
    func backfillThreads() throws -> Int {
        let spaces = try modelContext.fetch(FetchDescriptor<CachedSpace>())
        var linked = 0

        for space in spaces where space.isThreaded {
            let spaceName = space.name
            var threadsByName = Dictionary(
                try threads(inSpace: spaceName).map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // Fetched rather than read off `space.messages`, and narrowed to the rows
            // this actually links: the walk materialized every message in the room to
            // find the unlinked ones, and did it as a to-many fault. Messages with no
            // `threadName` are skipped by SQLite instead of by the loop.
            let unlinked = try modelContext.fetch(
                FetchDescriptor<CachedMessage>(
                    predicate: #Predicate<CachedMessage> { message in
                        message.space?.name == spaceName
                            && message.thread == nil
                            && message.threadName != nil
                    }
                )
            )
            var linkedHere = 0
            for message in unlinked {
                guard let threadName = message.threadName else { continue }
                message.thread = thread(named: threadName, in: space, cache: &threadsByName)
                linkedHere += 1
            }
            guard linkedHere > 0 else { continue }
            try refreshThreadState(in: space)
            linked += linkedHere
        }

        if linked > 0 { try modelContext.save() }
        return linked
    }

    func thread(named name: String) throws -> CachedThread? {
        var descriptor = FetchDescriptor<CachedThread>(
            predicate: #Predicate { $0.name == name }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
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
        threadName: String?,
        quotedMessageName: String? = nil,
        wireText: String? = nil
    ) throws {
        guard let space = try space(named: spaceName) else { return }

        let placeholder = CachedMessage(name: "\(spaceName)/messages/\(clientID)")
        placeholder.text = text
        // Only when it differs — see `CachedMessage.wireText`.
        placeholder.wireText = wireText
        placeholder.createTime = Date()
        placeholder.senderName = senderName
        placeholder.senderDisplayName = senderDisplayName
        placeholder.threadName = threadName
        placeholder.isThreadReply = threadName != nil
        placeholder.isPending = true
        placeholder.space = space
        // Carried on the local echo so the reply renders with its quote immediately,
        // and so a failed send still knows what it was answering when it is retried.
        placeholder.quotedMessageName = quotedMessageName

        modelContext.insert(placeholder)

        // Replying to a thread is reading it. Without this your own reply would come
        // straight back as an unread one.
        if space.isThreaded, let threadName {
            var threadsByName = try threads(named: [threadName])
            let row = thread(named: threadName, in: space, cache: &threadsByName)
            placeholder.thread = row
            row.lastReadTime = Date()
            row.didSeedReadState = true
            try refreshThreadState(of: row, in: space)
        }

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
            // The server stamps its own createTime, which can land after the mark set
            // when the placeholder went in — a few seconds of clock skew is enough.
            // Carrying the mark forward stops your own reply reappearing as unread.
            if let thread = confirmed.thread, let created = confirmed.createTime,
               created > (thread.lastReadTime ?? .distantPast) {
                thread.lastReadTime = created
                thread.didSeedReadState = true
                try refreshThreadState(of: thread, in: space)
            }
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
    ///
    /// - Parameter formattedText: the server's formatted copy of the new body. Written
    ///   even when nil, unlike most fields here: leaving the old one in place would
    ///   render the message as it read before the edit until some later sync replaced
    ///   it — the one stale value the transcript cannot hide.
    func applyEdit(to name: String, text: String, formattedText: String?) throws {
        guard let message = try message(named: name) else { return }
        message.text = text
        message.formattedText = formattedText
        message.lastUpdateTime = Date()
        try modelContext.save()
    }

    /// Tombstones a message locally. Chat keeps deleted messages visible as
    /// "Message deleted", so the row stays rather than vanishing.
    /// - Parameter includingThreadReplies: matches a forced delete, where Chat took
    ///   the whole thread down rather than just the message named here. Without it the
    ///   replies would sit in the cache as messages that no longer exist server-side,
    ///   until some later sync noticed.
    func applyDeletion(to name: String, includingThreadReplies: Bool = false) throws {
        guard let message = try message(named: name) else { return }
        tombstone(message)
        if includingThreadReplies, let thread = message.thread {
            let threadName = thread.name
            let replies = try modelContext.fetch(
                FetchDescriptor<CachedMessage>(
                    predicate: #Predicate<CachedMessage> { reply in
                        reply.threadName == threadName
                            && reply.isThreadReply
                            && reply.deleteTime == nil
                    }
                )
            )
            for reply in replies { tombstone(reply) }
        }
        // A deleted reply is not one the user still has to go and read.
        if let thread = message.thread, let space = thread.space {
            try refreshThreadState(of: thread, in: space)
        }
        try modelContext.save()
    }

    private func tombstone(_ message: CachedMessage) {
        message.deleteTime = Date()
        message.text = nil
        message.formattedText = nil
    }

    // MARK: - Links

    /// Resolves a `chat.google.com` link against what is actually cached.
    ///
    /// Answered here in one hop rather than as three separate questions from the UI,
    /// because the three are only meaningful together: whether the conversation is
    /// known, whether the message it names is cached, and whether that message is a
    /// reply in a threaded space — where the transcript holds no position to scroll to
    /// and the thread pane is the only way in.
    func destination(of link: ChatDeepLink) throws -> ChatLinkDestination {
        guard let space = try space(named: link.spaceName) else { return .unknownSpace }

        guard let messageName = link.messageName else {
            // A thread is somewhere to go only where threads are a place of their own.
            // Elsewhere its replies are already in the transcript.
            if let threadName = link.threadName, space.isThreaded {
                return .thread(threadName, message: nil)
            }
            return .space
        }

        guard let message = try message(named: messageName) else { return .uncachedMessage }
        if space.isThreaded, message.isThreadReply, let threadName = message.threadName {
            // The reply is carried along with the thread it is in: the pane has a
            // position for it even though the transcript does not.
            return .thread(threadName, message: messageName)
        }
        return .message(messageName)
    }

    // MARK: - Queries

    /// Where a message was aimed, for a retry to reproduce.
    ///
    /// A plain value rather than the row itself: `CachedMessage` belongs to this
    /// actor's context and cannot cross back to the caller.
    func sendContext(for messageName: String) throws -> SendContext? {
        guard let message = try message(named: messageName) else { return nil }
        return SendContext(
            threadName: message.threadName,
            quotedMessageName: message.quotedMessageName,
            wireText: message.wireText
        )
    }

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
        // `fetchCount`, not `!space.messages.isEmpty`: the relationship answers the same
        // question by faulting every message in the space into memory.
        let cached = try modelContext.fetchCount(
            FetchDescriptor<CachedMessage>(
                predicate: #Predicate<CachedMessage> { $0.space?.name == spaceName }
            )
        )
        return (space.backfillPageToken, space.backfillComplete, cached > 0)
    }
}

/// Everything a retry needs that the text alone does not carry: the thread the message
/// belongs to, the message it quotes, and the mention markup it was posted with.
nonisolated struct SendContext: Sendable, Equatable {
    var threadName: String?
    var quotedMessageName: String?
    /// See `CachedMessage.wireText`. Nil when the message mentions nobody.
    var wireText: String?
}
