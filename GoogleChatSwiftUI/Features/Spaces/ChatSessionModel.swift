import AppKit
import Foundation
import Observation
import OSLog
import SwiftData

/// Owns sync state for the signed-in session and drives the sidebar + message pane.
@MainActor
@Observable
final class ChatSessionModel {
    enum SpacesState: Equatable {
        case idle
        case refreshing
        case ready(count: Int)
        case failed(String)
    }

    private(set) var spacesState: SpacesState = .idle

    /// Comparing the enum inline (`state == .refreshing`) inside a view modifier
    /// blows the type checker's budget, so the check lives here.
    var isRefreshingSpaces: Bool {
        if case .refreshing = spacesState { return true }
        return false
    }
    private(set) var loadingSpaceNames: Set<String> = []
    private(set) var messageError: String?

    var scope: SpaceScope = .recent
    var kind: SpaceKind = .all
    /// Muted conversations are hidden by default: the point of muting one is not to
    /// think about it. Pinned ones are listed regardless — see `visibleSpaces`.
    var showsMuted: Bool = false
    /// Filters the sidebar's conversation list.
    var searchText: String = ""

    /// Searches message bodies. Separate from `searchText`, which filters
    /// conversation names — conflating them would make one field mean two things.
    var messageQuery: String = ""
    var messageSearchScope: MessageSearchScope = .allConversations
    /// Message the transcript should jump to, set when a search result is opened.
    var scrollTarget: String?
    /// Message the open thread should jump to. The thread pane's own target rather than
    /// a share of the one above: both surfaces are on screen at once, so a single value
    /// would have two readers racing to consume and clear it.
    var threadScrollTarget: String?
    /// The message a jump landed on, marked until the mark has been seen — see
    /// ``MessageHighlight``. Set here rather than by the surface that draws it because
    /// the thing being marked outlives the view: a link can arrive before the transcript
    /// it points into exists.
    private(set) var highlightedMessage: String?
    /// Clears the mark. Held so a second jump replaces the first's mark rather than
    /// having its own cleared out from under it by the older timer.
    private var highlightTask: Task<Void, Never>?

    /// How long the mark stays. Long enough to be found by someone who looked away while
    /// the conversation was opening, and short enough that it is gone before it starts
    /// looking like a selection.
    private static let highlightDuration = Duration.seconds(5)

    var isSearchingMessages: Bool {
        messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }
    var selectedSpaceName: String?

    /// What the right-hand inspector is showing.
    ///
    /// One state rather than two flags because the list and a single thread are two
    /// views of the same panel, and a thread opened from the list has somewhere to go
    /// back to — which a pair of independent booleans cannot express.
    enum ThreadInspector: Equatable {
        case closed
        case list
        case thread(name: String, cameFromList: Bool)
    }

    private(set) var threadInspector: ThreadInspector = .closed

    /// Where the user had read to in the open thread, captured as it was opened.
    ///
    /// Opening a thread clears its unread mark immediately, which would otherwise
    /// destroy the only evidence of where the new replies begin — the answer to the
    /// question that made them open it.
    private(set) var openedThreadReadMark: Date?

    /// Thread currently open in the inspector, e.g. `spaces/A/threads/B`.
    var selectedThreadName: String? {
        if case .thread(let name, _) = threadInspector { return name }
        return nil
    }

    var isThreadListOpen: Bool { threadInspector == .list }

    /// Whether the open thread has a list behind it to return to.
    var canReturnToThreadList: Bool {
        if case .thread(_, let cameFromList) = threadInspector { return cameFromList }
        return false
    }

    private(set) var sendingSpaceNames: Set<String> = []
    private(set) var realtimeStatus: RealtimeCoordinator.Status = .stopped
    private(set) var totalUnread = 0
    /// The user's own reaction history, driving the quick-pick row.
    let recentEmoji = RecentEmojiStore()
    private let notifications = NotificationService()

    private let sync: SyncEngine
    private let realtime: RealtimeCoordinator
    private let profile: GoogleUserProfile?
    private let logger = AppLog.logger("session")

    init(tokenProvider: TokenProvider, container: ModelContainer, profile: GoogleUserProfile?) {
        let client = ChatClient(tokenProvider: tokenProvider)
        let store = ChatStore(modelContainer: container)
        let engine = SyncEngine(client: client, store: store)
        sync = engine
        realtime = RealtimeCoordinator(
            transport: client.transport,
            sync: engine,
            store: store
        )
        self.profile = profile
    }

    // MARK: - Realtime

    func startRealtime() async {
        await realtime.setSelfChatName(profile?.chatUserName)
        await realtime.setSignedInAddress(profile?.emailAddress)
        await realtime.onStatusChange { [weak self] status in
            Task { @MainActor in self?.realtimeStatus = status }
        }
        await realtime.onIncomingMessage { [weak self] incoming in
            Task { @MainActor in await self?.handleIncoming(incoming) }
        }
        await notifications.requestAuthorization()
        await realtime.start()
        await refreshUnread()
    }

    /// Notifies and re-badges for a message that arrived from the event stream.
    private func handleIncoming(_ incoming: RealtimeCoordinator.IncomingMessage) async {
        // Reading it is what the user is doing right now, so the arrival should not
        // leave a badge behind. Only when the window is actually frontmost: a message
        // in the last-selected space of a backgrounded app is unread like any other.
        let isOnScreen = incoming.spaceName == selectedSpaceName
            && NSApplication.shared.isActive
        if isOnScreen {
            try? await sync.markRead(spaceName: incoming.spaceName)
        }

        // Muting has to mean silence, not just a different place in the sidebar —
        // a muted space that still raises banners is not muted in any sense the
        // user would recognise. The message is still cached and still counted;
        // only the alert is dropped.
        let isMuted = (try? await sync.isMuted(spaceName: incoming.spaceName)) ?? false

        await notifications.notify(
            spaceTitle: incoming.spaceTitle,
            senderName: incoming.senderDisplayName,
            body: incoming.body,
            spaceName: incoming.spaceName,
            // Suppressed for the conversation already on screen — an alert for
            // something the user is looking at is pure noise.
            isSpaceVisible: isOnScreen,
            isMuted: isMuted
        )
        await refreshUnread()
    }

    /// Opens a conversation on behalf of something outside the sidebar — a clicked
    /// notification — where the current view may be showing something else entirely.
    func revealSpace(_ spaceName: String) async {
        // A message search replaces the transcript with results, so a click that says
        // "show me this conversation" has to clear it or nothing appears to happen.
        messageQuery = ""
        await openSpace(spaceName)
    }

    // MARK: - Direct messages

    /// Finds the one-to-one conversation with a person, creating it if this account has
    /// never had one with them.
    ///
    /// Stops short of opening it, because the caller has something to do first: the
    /// sidebar's filters have to make room for the conversation before it is selected,
    /// or the transcript opens with no row to be selected in and no sense of where you
    /// are. See `SpacesListView.openDirectMessage(with:)`.
    ///
    /// - Parameter userID: Chat user resource name, e.g. `users/1234567890`.
    /// - Returns: the space to open, or nil when it could not be resolved — reported
    ///   through `messageError`, like any other failed request.
    func directMessageSpace(with userID: String) async -> String? {
        do {
            return try await sync.directMessage(with: userID)
        } catch {
            logger.error("DM lookup for \(userID) failed: \(error.localizedDescription)")
            messageError = "Couldn't open that chat. \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Links

    /// Why a link could not be followed all the way to what it named. Nil the rest of
    /// the time, which is nearly always.
    private(set) var linkNotice: String?

    func dismissLinkNotice() {
        linkNotice = nil
    }

    // MARK: - Going to a message

    /// Sends the transcript to a message and marks it once it is there.
    ///
    /// The two halves are one action and are called as one: a scroll with nothing marked
    /// leaves the reader guessing which of the messages now on screen they were brought
    /// for, which is the complaint every caller here would otherwise produce.
    func jump(to messageName: String) {
        scrollTarget = messageName
        markLanding(on: messageName)
    }

    /// The same, for a message that lives in the thread pane rather than the transcript.
    func jumpInThread(to messageName: String) {
        threadScrollTarget = messageName
        markLanding(on: messageName)
    }

    private func markLanding(on messageName: String) {
        highlightTask?.cancel()
        highlightedMessage = messageName
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: Self.highlightDuration)
            guard !Task.isCancelled else { return }
            guard self?.highlightedMessage == messageName else { return }
            self?.highlightedMessage = nil
        }
    }

    /// Drops any mark and the timer that would have dropped it. Called when leaving the
    /// conversation the marked message is in, since a mark waiting in a transcript nobody
    /// is looking at would be there to greet whoever opens it next.
    private func clearLanding() {
        highlightTask?.cancel()
        highlightTask = nil
        highlightedMessage = nil
    }

    /// Follows a `chat.google.com` link inside the app.
    ///
    /// The caller has already established that this account knows the conversation —
    /// see `SpacesListView.openChatLink`, which hands anything else to the browser.
    func reveal(_ link: ChatDeepLink) async {
        await revealSpace(link.spaceName)

        var destination = await resolvedDestination(of: link)

        // A message the cache has not reached yet is worth a few pages of history: a
        // link is nearly always to something recent, and the alternative is leaving
        // someone to scroll back for it themselves when the app could have fetched it
        // while they were still looking at the conversation. Bounded, because
        // walking a years-old space to its beginning is not what one click should cost.
        var passes = 0
        while destination == .uncachedMessage, passes < 4 {
            passes += 1
            let hasMore = await loadOlderMessages(in: link.spaceName)
            destination = await resolvedDestination(of: link)
            if !hasMore { break }
        }

        // Discarded if the reader has moved on in the meantime — a slow backfill must
        // not yank a transcript nobody is looking at any more.
        guard selectedSpaceName == link.spaceName else { return }

        switch destination {
        case .message(let messageName):
            jump(to: messageName)
        case .thread(let threadName, let messageName):
            openThread(threadName)
            // A link to one reply among dozens needs the mark more than the transcript
            // does: the pane opens on the newest reply, which is rarely the one meant.
            if let messageName { jumpInThread(to: messageName) }
        case .uncachedMessage:
            linkNotice = """
                That message is older than the history downloaded for this conversation. \
                Scrolling to the top of the transcript fetches more of it.
                """
        case .space, .unknownSpace:
            break
        }
    }

    private func resolvedDestination(of link: ChatDeepLink) async -> ChatLinkDestination {
        do {
            return try await sync.destination(of: link)
        } catch {
            logger.error("Link resolution failed: \(error.localizedDescription)")
            return .space
        }
    }

    /// Recomputes the badge total from the cache.
    func refreshUnread() async {
        do {
            totalUnread = try await sync.totalUnread()
            await notifications.setBadge(totalUnread)
        } catch {
            logger.error("Unread tally failed: \(error.localizedDescription)")
        }
    }

    /// Indexes existing cached messages so search covers them.
    func prepareSearchIndex() async {
        do {
            let indexed = try await sync.backfillSearchIndex()
            if indexed > 0 { logger.info("Indexed \(indexed) message(s) for search") }
        } catch {
            logger.error("Search index backfill failed: \(error.localizedDescription)")
        }
    }

    /// Fetches read state in bounded passes, like title resolution.
    func loadReadStates() async {
        for _ in 0..<40 {
            if Task.isCancelled { return }
            do {
                guard try await sync.pendingReadStateCount() > 0 else { break }
                try await sync.refreshReadStates()
                try? await Task.sleep(for: .milliseconds(250))
            } catch {
                logger.error("Read state pass failed: \(error.localizedDescription)")
                break
            }
        }
        await refreshUnread()
    }

    func stopRealtime() async {
        await realtime.stop()
    }

    /// Closes gaps the event stream may have dropped while the app was asleep or
    /// offline. Events are best-effort, so this is not optional.
    func reconcileSelectedSpace() async {
        guard let spaceName = selectedSpaceName else { return }
        await realtime.reconcile(spaceName: spaceName)
    }

    func refreshSpaces() async {
        spacesState = .refreshing
        do {
            let count = try await sync.refreshSpaces()
            spacesState = .ready(count: count)
        } catch {
            logger.error("Space refresh failed: \(error.localizedDescription)")
            spacesState = .failed(error.localizedDescription)
        }
        // Sections are cheap and shape the whole sidebar, so they refresh with the
        // space list rather than in bounded passes.
        do {
            if let user = profile?.chatUserName {
                try await sync.refreshSections(user: user)
            }
        } catch {
            // Google currently answers users.sections.list with 500 INTERNAL for this
            // account, with either `users/me` or the numeric id, and the scope is
            // granted — so this is server-side, not something the client can fix. The
            // sidebar falls back to one flat group, so it is logged once at info level
            // rather than shouted about as an error on every launch.
            logger.info("Sections unavailable: \(error.localizedDescription)")
        }
        await resolveTitles()
    }

    // MARK: - Local sidebar preferences

    /// Pin and mute are this app's own state — see `CachedSpace.isPinned`. Nothing
    /// is sent to Chat, so these cannot fail for a network reason and there is no
    /// optimistic update to roll back.
    func setPinned(_ pinned: Bool, for spaceName: String) async {
        do {
            try await sync.setPinned(pinned, for: spaceName)
        } catch {
            logger.error("Pin toggle failed: \(error.localizedDescription)")
        }
    }

    /// - Parameter spaceNames: the pinned group in its new order, top first.
    func reorderPinned(_ spaceNames: [String]) async {
        do {
            try await sync.reorderPinned(spaceNames)
        } catch {
            logger.error("Pin reorder failed: \(error.localizedDescription)")
        }
    }

    func setMuted(_ muted: Bool, for spaceName: String) async {
        do {
            try await sync.setMuted(muted, for: spaceName)
            // Muting something you are looking at would otherwise drop it out of the
            // sidebar while it stays open in the transcript, which reads as a bug.
            if muted, !showsMuted, spaceName == selectedSpaceName { showsMuted = true }
            // Muted spaces are out of the badge total, so it moves the moment
            // this is toggled either way.
            await refreshUnread()
        } catch {
            logger.error("Mute toggle failed: \(error.localizedDescription)")
        }
    }

    /// Fills in DM and group-chat names, which Chat does not supply.
    ///
    /// Runs to completion across every space, in bounded concurrent passes, so the
    /// sidebar fills in progressively rather than stalling. Names are cached
    /// permanently, so this is a one-time cost on first launch — but it has to cover
    /// all spaces, not just recent ones, or search would return unnamed rows.
    func resolveTitles() async {
        // Generous ceiling rather than an exact count: a safety net against a bug
        // that never marks spaces resolved, not a real expected bound.
        let maxPasses = 60

        for pass in 0..<maxPasses {
            if Task.isCancelled { return }
            do {
                guard try await sync.pendingTitleCount() > 0 else {
                    if pass > 0 { logger.info("Title resolution complete after \(pass) pass(es)") }
                    return
                }
                try await sync.resolvePendingTitles(excludingUser: profile?.chatUserName)
                // Smooths the request rate: Chat quotas are per-user-per-minute and
                // a few hundred member lookups back-to-back would trip them.
                try? await Task.sleep(for: .milliseconds(250))
            } catch {
                logger.error("Title resolution failed: \(error.localizedDescription)")
                return
            }
        }
        logger.warning("Title resolution hit its pass ceiling with work remaining")
    }

    /// Called when a space is selected. Fetches history only if nothing is cached,
    /// which is what keeps 762 spaces affordable.
    func openSpace(_ spaceName: String) async {
        if selectedSpaceName != spaceName { threadInspector = .closed }
        selectedSpaceName = spaceName
        // The query was the means of finding this conversation, and it has served its
        // purpose the moment the conversation is open. Left applied it would hold the
        // sidebar down to a handful of rows — so the next glance at the list shows a
        // near-empty sidebar, with the reason for it sitting in a field nobody is
        // looking at any more.
        searchText = ""
        messageError = nil
        // Belongs to whichever conversation the last link pointed into, so it goes when
        // that conversation does. `reveal(_:)` sets its own after this returns.
        linkNotice = nil
        // Any jump left over from an earlier search belongs to a transcript nobody is
        // looking at now. The search flow sets its own target after this returns; every
        // other way into a conversation should open it at the newest message.
        scrollTarget = nil
        threadScrollTarget = nil
        clearLanding()
        guard !loadingSpaceNames.contains(spaceName) else { return }

        loadingSpaceNames.insert(spaceName)
        defer { loadingSpaceNames.remove(spaceName) }

        do {
            try await sync.prepareHistory(for: spaceName)
            // Opening a conversation is reading it. Best-effort: failing to clear the
            // badge is not worth an error banner over the messages themselves.
            try? await sync.markRead(spaceName: spaceName)
            await refreshUnread()
        } catch {
            logger.error("History load failed for \(spaceName): \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    /// Marks one conversation read, threads included.
    ///
    /// Threads are cleared here where opening the space deliberately leaves them
    /// alone: this is an explicit instruction about the whole conversation, not the
    /// side effect of having looked at its transcript.
    func markRead(_ spaceName: String) async {
        do {
            try await sync.markRead(spaceName: spaceName)
            try await sync.markAllThreadsRead(spaceName: spaceName)
            await refreshUnread()
        } catch {
            logger.error("Mark read failed: \(error.localizedDescription)")
        }
    }

    /// Marks a conversation unread and steps out of it.
    ///
    /// Closing it is the point. Opening a space marks it read, so a conversation left
    /// on screen would be wearing a badge that the next click erases — and the reason
    /// to mark something unread is to deal with it later, somewhere else.
    func markUnread(_ spaceName: String) async {
        do {
            guard try await sync.markUnread(spaceName: spaceName) else { return }
            if selectedSpaceName == spaceName {
                selectedSpaceName = nil
                threadInspector = .closed
            }
            await refreshUnread()
        } catch {
            logger.error("Mark unread failed: \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    /// Marks every space with unread messages as read, threads included.
    ///
    /// Threads are cleared separately because a space read mark deliberately does not
    /// reach them — but "mark all as read" means all of it, including the replies the
    /// space mark cannot speak for.
    func markAllRead() async {
        do {
            let names = try await sync.unreadSpaceNames()
            for name in names {
                try? await sync.markRead(spaceName: name)
            }
            for name in try await sync.spacesWithUnreadThreads() {
                try? await sync.markAllThreadsRead(spaceName: name)
            }
            await refreshUnread()
        } catch {
            logger.error("Mark all read failed: \(error.localizedDescription)")
        }
    }

    /// - Returns: whether there is still older history beyond what this fetched, so a
    ///   caller paging towards something can stop at the beginning of the conversation
    ///   rather than asking again for a page that does not exist.
    @discardableResult
    func loadOlderMessages(in spaceName: String) async -> Bool {
        guard !loadingSpaceNames.contains(spaceName) else { return false }
        loadingSpaceNames.insert(spaceName)
        defer { loadingSpaceNames.remove(spaceName) }

        do {
            return try await sync.loadMoreHistory(for: spaceName)
        } catch {
            logger.error("Paging failed for \(spaceName): \(error.localizedDescription)")
            messageError = error.localizedDescription
            return false
        }
    }

    func isLoading(_ spaceName: String) -> Bool {
        loadingSpaceNames.contains(spaceName)
    }

    func isSending(_ spaceName: String) -> Bool {
        sendingSpaceNames.contains(spaceName)
    }

    // MARK: - Writes

    /// Opens a thread in the inspector. Selecting a different space closes it, since
    /// a thread from another conversation would be stale context.
    ///
    /// Opening is reading: the mark advances here rather than when the pane draws, so
    /// it happens once per open regardless of how the view is rebuilt.
    func openThread(_ threadName: String, fromList: Bool = false) {
        threadInspector = .thread(name: threadName, cameFromList: fromList)
        openedThreadReadMark = nil
        // Opening a thread by hand opens it at its newest reply. `reveal(_:)` sets its
        // own target after this returns, for the one case that has somewhere else to go.
        threadScrollTarget = nil
        Task {
            let previous = await markThreadRead(threadName)
            // Discarded if the user has already moved on, so a slow write cannot
            // draw someone else's read line into the thread now on screen.
            guard selectedThreadName == threadName else { return }
            openedThreadReadMark = previous
        }
    }

    /// Opens the space's thread list — the panel that makes an unread reply findable
    /// at all, since replies never appear in the main transcript.
    func openThreadList() {
        threadInspector = .list
    }

    func closeThreadInspector() {
        threadInspector = .closed
    }

    /// Backs out of a thread to the list it was opened from, or closes the panel when
    /// the thread was opened straight from the transcript.
    func closeThreadPane() {
        threadInspector = canReturnToThreadList ? .list : .closed
    }

    /// - Returns: where the user had previously read to in this thread, if anywhere.
    @discardableResult
    func markThreadRead(_ threadName: String) async -> Date? {
        do {
            let previous = try await sync.markThreadRead(threadName: threadName)
            await refreshUnread()
            return previous
        } catch {
            logger.error("Thread read mark failed: \(error.localizedDescription)")
            return nil
        }
    }

    func markAllThreadsRead(in spaceName: String) async {
        do {
            try await sync.markAllThreadsRead(spaceName: spaceName)
            await refreshUnread()
        } catch {
            logger.error("Marking threads read failed: \(error.localizedDescription)")
        }
    }

    /// Checks unread threads against the server's read marks, so a thread already
    /// read on chat.google.com does not sit here demanding attention.
    func refreshThreadReadStates(in spaceName: String) async {
        do {
            let checked = try await sync.refreshThreadReadStates(in: spaceName)
            if checked > 0 { await refreshUnread() }
        } catch {
            logger.error("Thread read state pass failed: \(error.localizedDescription)")
        }
    }

    /// Builds thread rows over messages cached before threads were tracked.
    func prepareThreadIndex() async {
        do {
            let linked = try await sync.backfillThreads()
            if linked > 0 { logger.info("Linked \(linked) message(s) to threads") }
        } catch {
            logger.error("Thread index backfill failed: \(error.localizedDescription)")
        }
    }

    /// - Parameter replyingTo: the message this one answers inline, if any. Its own
    ///   thread wins over `threadName`, because Chat refuses a quote that crosses
    ///   threads — see `ReplyTarget`.
    /// - Parameter mentions: the people `text` names, from the composer's completion.
    func send(
        _ text: String,
        to spaceName: String,
        threadName: String? = nil,
        replyingTo target: ReplyTarget? = nil,
        attachments: [PendingAttachment] = [],
        mentions: [MentionCandidate] = []
    ) async {
        messageError = nil
        sendingSpaceNames.insert(spaceName)
        defer { sendingSpaceNames.remove(spaceName) }

        do {
            try await sync.send(
                text: text,
                to: spaceName,
                threadName: target?.threadName ?? threadName,
                quotedMessageName: target?.messageName,
                attachments: attachments,
                mentions: mentions,
                senderName: profile?.chatUserName,
                senderDisplayName: profile?.displayName
            )
            // Sending implies reading. Best-effort: a failure here is not worth
            // surfacing over a successful send.
            try? await sync.markRead(spaceName: spaceName)
        } catch {
            messageError = error.localizedDescription
        }
    }

    func retrySend(messageName: String, text: String, in spaceName: String) async {
        messageError = nil
        sendingSpaceNames.insert(spaceName)
        defer { sendingSpaceNames.remove(spaceName) }

        do {
            try await sync.retrySend(
                messageName: messageName,
                text: text,
                in: spaceName,
                senderName: profile?.chatUserName,
                senderDisplayName: profile?.displayName
            )
        } catch {
            messageError = error.localizedDescription
        }
    }

    /// - Parameter mentions: who the edited text may name. See `MessageBubble.saveEdit`
    ///   for why an edit has to re-encode them rather than posting the text verbatim.
    func edit(messageName: String, newText: String, mentions: [MentionCandidate] = []) async {
        messageError = nil
        do {
            try await sync.edit(messageName: messageName, newText: newText, mentions: mentions)
        } catch {
            logger.error("Edit failed: \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    /// How a delete ended, because one of the endings is a question for the user.
    enum DeletionOutcome {
        case deleted
        /// Chat refused: the message starts a thread, and it will not leave the replies
        /// behind. Retrying with `force` deletes them too — an escalation the person
        /// deleting has to agree to, so the caller asks rather than this doing it.
        case needsThreadConfirmation
        case failed
    }

    /// - Parameter force: deletes the message's threaded replies along with it.
    @discardableResult
    func delete(messageName: String, force: Bool = false) async -> DeletionOutcome {
        messageError = nil
        do {
            try await sync.delete(messageName: messageName, force: force)
            return .deleted
        } catch let error as ChatAPIError where !force && error.requiresForcedDelete {
            return .needsThreadConfirmation
        } catch {
            logger.error("Delete failed: \(error.localizedDescription)")
            messageError = error.localizedDescription
            return .failed
        }
    }

    func discardFailedMessage(named name: String) async {
        try? await sync.discard(messageName: name)
    }

    func toggleReaction(_ emoji: String, on messageName: String) async {
        messageError = nil
        do {
            let didAdd = try await sync.toggleReaction(
                emoji: emoji,
                on: messageName,
                selfChatName: profile?.chatUserName
            )
            // Recorded only on success and only on add: a failed call is not a
            // preference, and removing a reaction is not a signal to suggest it.
            if didAdd { recentEmoji.record(emoji) }
        } catch {
            logger.error("Reaction toggle failed: \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    /// Who reacted to a message, keyed by emoji.
    ///
    /// Fetched on demand rather than cached with the reaction counts: the names are only
    /// ever wanted while a reader has the list open, and keeping them current would mean
    /// a listing call per message per sync pass.
    /// - Throws: rethrown so the sheet asking can show its own failure. `messageError`
    ///   is deliberately not set — a lookup that fails is not a failed write, and it
    ///   should not raise the banner that one does.
    func reactors(on messageName: String) async throws -> [String: [Reactor]] {
        try await sync.reactors(on: messageName, selfChatName: profile?.chatUserName)
    }

    func downloadAttachment(resourceName: String) async throws -> Data {
        try await sync.downloadAttachment(resourceName: resourceName)
    }

    /// Title and file kind for a Drive link, for the chips in the transcript to fill
    /// themselves in with. Nil where the file cannot be read — no access, deleted, or a
    /// sign-in that predates the Drive scope — and the caller keeps its plain form.
    func driveFile(id: String) async -> DriveFileMetadata? {
        await sync.driveFile(id: id)
    }

    /// Names an app sender — a Chat app or an incoming webhook.
    ///
    /// Local, and not for want of trying: Chat returns a sender's ID and type but never
    /// its `displayName` under user authentication, and the People API has no record of
    /// an app to fall back on. So the name is the user's, stored in the same row a
    /// resolved profile would occupy, which is what makes it show up in the transcript,
    /// the thread list, search and notification banners alike.
    /// - Parameter displayName: blank clears the name again.
    func setAppName(_ displayName: String?, for userID: String) async {
        messageError = nil
        do {
            try await sync.setLocalName(displayName, for: userID)
        } catch {
            logger.error("Naming app \(userID) failed: \(error.localizedDescription)")
            messageError = error.localizedDescription
        }
    }

    // MARK: - Mentions

    /// Members offered for `@` completion, by space.
    ///
    /// In memory rather than in the cache, and deliberately. Membership changes without
    /// telling this app — there is no event for it that we subscribe to — so a list
    /// rebuilt once per launch is fresher than a persisted one would be, and it saves
    /// a schema field for something that can always be fetched again.
    private var mentionableIDs: [String: [String]] = [:]

    /// Fetches the people who can be mentioned in a space, at most once per launch.
    ///
    /// On demand rather than with the space list: at 762 spaces a members call each
    /// would dwarf everything else the app does, and most spaces are never opened. The
    /// cost is one call the first time a conversation is looked at.
    func loadMentionableMembers(of spaceName: String) async {
        guard mentionableIDs[spaceName] == nil else { return }
        // Claimed before the await, so opening the transcript and its thread pane in
        // the same breath does not start the same fetch twice.
        mentionableIDs[spaceName] = []

        do {
            mentionableIDs[spaceName] = try await sync.mentionableMembers(
                in: spaceName,
                excluding: profile?.chatUserName
            )
        } catch {
            // Released rather than left empty: a space whose members could not be
            // fetched should try again the next time it is opened, not lose mentions
            // for the rest of the session over one failed request.
            mentionableIDs[spaceName] = nil
            logger.error("Member lookup failed for \(spaceName): \(error.localizedDescription)")
        }
    }

    /// Empty until ``loadMentionableMembers(of:)`` has returned, which just means the
    /// completion list stays shut rather than offering half a room.
    func mentionableUserIDs(in spaceName: String) -> [String] {
        mentionableIDs[spaceName] ?? []
    }

    /// Whether the signed-in user authored this message — the gate for edit/delete,
    /// which Chat only permits on your own messages.
    func isOwnMessage(_ message: CachedMessage) -> Bool {
        guard let mine = profile?.chatUserName, let sender = message.senderName else {
            return false
        }
        return mine == sender
    }
}
