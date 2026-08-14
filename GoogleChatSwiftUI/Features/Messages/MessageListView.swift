import SwiftData
import SwiftUI

/// Message history for one space, read from the cache.
///
/// Split into a shell and a transcript, and the split is load-bearing: a `@Query`
/// descriptor can only be built in `init`, so the window this view moves over the
/// conversation — which is state, and changes while the view is on screen — cannot live
/// in the same view as the query it sizes. The shell holds the window and the chrome;
/// ``ConversationTranscript`` below owns the queries built from it. See
/// ``TranscriptWindow`` for why the transcript is windowed at all.
///
/// Both this view and its state are per conversation: `SpacesListView` gives the detail
/// pane an identity tied to the space, so switching conversations builds this afresh
/// rather than carrying the last one's window into it.
struct MessageListView: View {
    @Environment(ChatSessionModel.self) private var session
    /// For the two counts the window is sized by. Both are counts rather than fetches:
    /// the answers are numbers, and every row would be thrown away.
    @Environment(\.modelContext) private var modelContext

    private let spaceName: String
    private let spaceTitle: String
    private let isThreaded: Bool
    /// Threads here with unread replies, for the toolbar badge.
    private let unreadThreadCount: Int
    /// Whether the conversation has history the *cache* has not walked back to yet. False
    /// at the first message ever sent here, which is where asking Chat for more stops.
    /// Says nothing about the window, which can have plenty left to show in a space that
    /// has been backfilled to its beginning.
    private let hasOlderHistory: Bool

    /// How far back the transcript is drawn.
    @State private var window = TranscriptWindow()
    /// The message to keep still while older history loads in above it, captured as the
    /// request is made rather than after — by the time it returns, the row that was at
    /// the top is no longer the one to hold onto.
    @State private var historyAnchor: String?
    /// A jump the transcript has not made yet.
    ///
    /// Taken from `session.scrollTarget` here rather than handed straight to the scroll
    /// view, because a target older than the window is in no transcript to be scrolled
    /// to: the window has to open past it first, and only then is there a row to aim at.
    @State private var pendingJump: String?

    init(
        spaceName: String,
        spaceTitle: String,
        isThreaded: Bool,
        unreadThreadCount: Int,
        hasOlderHistory: Bool
    ) {
        self.spaceName = spaceName
        self.spaceTitle = spaceTitle
        self.isThreaded = isThreaded
        self.unreadThreadCount = unreadThreadCount
        self.hasOlderHistory = hasOlderHistory
    }

    var body: some View {
        ConversationTranscript(
            spaceName: spaceName,
            spaceTitle: spaceTitle,
            isThreaded: isThreaded,
            limit: window.limit,
            hasOlderHistory: hasOlderHistory,
            historyAnchor: $historyAnchor,
            jumpTarget: $pendingJump,
            onReachStart: loadOlder
        )
        .navigationTitle(spaceTitle)
        .toolbar {
            // Only where threads are a place of their own. In grouped and unthreaded
            // spaces replies are already in the transcript, so a thread index would
            // just be a second copy of what is on screen.
            if isThreaded {
                ToolbarItem(placement: .primaryAction) { threadsButton }
                // Separates this view's own items from the account control. Only where
                // there is something to separate it from — leading a toolbar with a
                // spacer just indents the one button that is left.
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            // Last of this view's own items, and declared here rather than on the
            // split view, because that is what puts it after them — see
            // `AccountToolbarButton`. The search field lands to its right whatever
            // any of this says: SwiftUI pins it to the trailing end of the toolbar.
            ToolbarItem(placement: .primaryAction) {
                AccountToolbarButton()
            }
        }
        // Members are fetched per space and only once per launch, so this is one call
        // the first time a conversation is opened rather than anything the sidebar
        // pays for — at 762 spaces, a members lookup each would dwarf the whole app.
        .task(id: spaceName) { await session.loadMentionableMembers(of: spaceName) }
        // `initial` because a jump routinely arrives before this view does: following a
        // link or opening a search hit selects the conversation first, and the target is
        // set while the transcript for it is still being built.
        .onChange(of: session.scrollTarget, initial: true) { _, target in
            guard let target else { return }
            session.scrollTarget = nil
            window.reach(pastNewerMessages: messagesNewer(than: target))
            pendingJump = target
        }
    }

    /// Opens the thread index, and says how much is waiting in it.
    ///
    /// Carries a count rather than a plain icon because the count is the whole point:
    /// an unread reply is invisible everywhere else in this window once the space has
    /// been opened, so this is the only thing that can tell the user to look.
    private var threadsButton: some View {
        Button {
            if session.isThreadListOpen {
                session.closeThreadInspector()
            } else {
                session.openThreadList()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.bubble.right")
                if unreadThreadCount > 0 {
                    Text("\(unreadThreadCount)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: .capsule)
                }
            }
        }
        .help(threadsHelp)
        .accessibilityLabel(threadsHelp)
    }

    private var threadsHelp: String {
        guard unreadThreadCount > 0 else { return "Threads" }
        let noun = unreadThreadCount == 1 ? "thread" : "threads"
        return "Threads — \(unreadThreadCount) unread \(noun)"
    }

    // MARK: - Reaching the top

    /// Fetches whatever is above the transcript, which is two different things.
    ///
    /// Cached history below the window is shown by widening it: no request, no wait, and
    /// the rows are already on disk. Only a window that has reached the oldest cached
    /// message asks Chat for a page — and widens as well, so that the page has somewhere
    /// to land when it arrives.
    ///
    /// The row to keep still is the one that is oldest *now*, captured before either
    /// happens rather than after: by the time history lands, the top of the transcript is
    /// what just arrived, and holding that would leave the reader where they already were
    /// rather than where they were reading.
    private func loadOlder(holding anchor: String?) {
        historyAnchor = anchor
        let isCacheExhausted = window.coversEverythingCached(cachedMessageCount())
        window.widen()
        guard isCacheExhausted else { return }
        Task { await session.loadOlderMessages(in: spaceName) }
    }

    /// How many messages this space has cached in total — what says whether widening the
    /// window would reveal anything. See ``TranscriptWindow/coversEverythingCached(_:)``.
    private func cachedMessageCount() -> Int {
        let descriptor = TranscriptQueries.allMessages(in: spaceName)
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// How many cached messages in this space are newer than the named one — which is
    /// exactly how far the window has to open for it to be in the transcript at all.
    ///
    /// Zero for a message this account has never cached, which leaves the window as it
    /// was: there is no row to reach, and `ChatSessionModel.reveal(_:)` has already said
    /// so in the banner above the composer.
    private func messagesNewer(than messageName: String) -> Int {
        let lookup = TranscriptQueries.message(named: messageName)
        guard let target = try? modelContext.fetch(lookup).first,
              let created = target.createTime
        else { return 0 }

        let descriptor = TranscriptQueries.messages(in: spaceName, after: created)
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

/// The conversation itself: the windowed transcript, the composer beneath it, and the
/// queries both read from.
///
/// A view of its own for `@Query`'s one constraint — a descriptor is built in `init`, so
/// anything that sizes one has to arrive as a parameter rather than be read from state.
/// Here that is `limit`, the window ``MessageListView`` above moves.
private struct ConversationTranscript: View {
    @Environment(ChatSessionModel.self) private var session
    /// The newest `limit` messages in this space, newest first.
    ///
    /// The order is not the transcript's — ``days`` buckets and sorts regardless of what
    /// arrives. It is sorted this way so that the limit means *the newest*, which is the
    /// only end of a conversation worth opening on.
    @Query private var messages: [CachedMessage]
    /// Sender identity lives in `CachedUser`, not on the message, so one directory
    /// fetch names every message that person has ever sent — including ones already
    /// cached before the lookup happened.
    @Query private var users: [CachedUser]
    /// Thread index rows for this space, carrying the per-thread reply and unread counts
    /// the transcript cannot count for itself once it is windowed.
    @Query private var threads: [CachedThread]

    private let spaceName: String
    private let spaceTitle: String
    private let isThreaded: Bool
    private let limit: Int
    private let hasOlderHistory: Bool

    @Binding private var historyAnchor: String?
    @Binding private var jumpTarget: String?
    /// Asks for whatever is above the transcript, holding the given row still while it
    /// arrives. See ``MessageListView/loadOlder(holding:)``.
    private let onReachStart: (String?) -> Void

    /// Bumped on send, which is the one moment the transcript should return to the
    /// end whether or not the reader was there.
    @State private var sendCount = 0
    /// The message the next send will quote, when the reader has chosen to reply to
    /// one. Held here rather than in the composer because the choice is made in the
    /// transcript and the send is aimed from here.
    @State private var replyTarget: ReplyTarget?

    init(
        spaceName: String,
        spaceTitle: String,
        isThreaded: Bool,
        limit: Int,
        hasOlderHistory: Bool,
        historyAnchor: Binding<String?>,
        jumpTarget: Binding<String?>,
        onReachStart: @escaping (String?) -> Void
    ) {
        self.spaceName = spaceName
        self.spaceTitle = spaceTitle
        self.isThreaded = isThreaded
        self.limit = limit
        self.hasOlderHistory = hasOlderHistory
        _historyAnchor = historyAnchor
        _jumpTarget = jumpTarget
        self.onReachStart = onReachStart

        _messages = Query(TranscriptQueries.window(in: spaceName, limit: limit))

        _threads = Query(
            filter: #Predicate<CachedThread> { $0.space?.name == spaceName },
            sort: [SortDescriptor(\CachedThread.lastActivityTime, order: .reverse)]
        )
    }

    var body: some View {
        // Built once here and handed down, rather than reached for per row. See
        // ``TranscriptIndex``.
        let index = TranscriptIndex(
            users: users,
            messages: messages,
            threads: threads,
            mentionableIDs: session.mentionableUserIDs(in: spaceName),
            isThreaded: isThreaded
        )

        return Group {
            if messages.isEmpty {
                emptyState
            } else {
                transcript(index)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composerArea(index) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if session.isLoading(spaceName) {
            ProgressView("Loading messages…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Messages",
                systemImage: "bubble",
                description: Text("Say something to start the conversation.")
            )
        }
    }

    /// The composer and the two banners that sit above it.
    private func composerArea(_ index: TranscriptIndex) -> some View {
        VStack(spacing: 0) {
            if let error = session.messageError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
            }
            // A followed link that could not reach the message it named. Stated
            // rather than silently ignored: the alternative is a click that opens
            // the right conversation at the wrong place and explains nothing.
            if let notice = session.linkNotice {
                linkNoticeBanner(notice)
            }
            MessageComposer(
                placeholder: replyTarget == nil ? "Message \(spaceTitle)" : "Reply",
                isSending: session.isSending(spaceName),
                replyTarget: replyTarget,
                onCancelReply: { replyTarget = nil },
                mentionCandidates: index.mentionCandidates,
                recentEmoji: session.recentEmoji.recents,
                onUseEmoji: { session.recentEmoji.record($0) }
            ) { composed in
                let target = replyTarget
                replyTarget = nil
                sendCount += 1
                Task {
                    await session.send(
                        composed.text,
                        to: spaceName,
                        replyingTo: target,
                        attachments: composed.attachments,
                        mentions: composed.mentions
                    )
                }
            }
        }
    }

    /// Information rather than failure, so it is styled as a note and not as the red
    /// error above it — nothing went wrong, the history simply does not go back that far.
    private func linkNoticeBanner(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
            Text(notice)
            Spacer(minLength: 8)
            Button("Dismiss") { session.dismissLinkNotice() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary)
    }

    /// The conversation, positioned by `TranscriptScrollView`.
    ///
    /// Every scroll decision lives there rather than being spread across anchors and
    /// change handlers here: where to open, whether an arriving message should pull the
    /// view down, when reaching the top means fetch more, and how to stand still while
    /// older history is inserted above. The grouped days are computed once and handed
    /// over, since they are needed both as content and as the two identities that tell
    /// the scroll view which end moved.
    private func transcript(_ index: TranscriptIndex) -> some View {
        let groups = days
        let oldestID = groups.first?.entries.first?.message.name

        return TranscriptScrollView(
            newestID: groups.last?.entries.last?.message.name,
            oldestID: oldestID,
            horizontalPadding: 16,
            verticalPadding: 12,
            jumpTarget: $jumpTarget,
            historyAnchor: $historyAnchor,
            followTrigger: sendCount,
            isLoadingOlder: session.isLoading(spaceName),
            // Nothing above the transcript at the beginning of the conversation, and
            // saying so is what stops it asking every time the reader rests there.
            onReachStart: hasMoreAbove ? { onReachStart(oldestID) } : nil
        ) {
            ForEach(groups, id: \.day) { group in
                DayDivider(day: group.day)

                ForEach(group.entries, id: \.message.name) { entry in
                    row(for: entry, index: index)
                        .id(entry.message.name)
                }
            }
        }
        // Outside the scroll content on purpose: inside, its appearance and removal
        // displaced every message below it.
        .overlay(alignment: .top) {
            if session.isLoading(spaceName) {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.top, 6)
            }
        }
    }

    /// Whether reaching the top has anything to reach for: history the window has not
    /// opened onto yet, or a page still on the server.
    ///
    /// A full window is the signal for the first, since a query that returns everything
    /// it was allowed to may well have been holding more back. It can be wrong once, in
    /// the space whose cache ends exactly at the window's edge — and being wrong once
    /// costs a widening that reveals nothing and then answers false, rather than a
    /// transcript that refuses to page.
    private var hasMoreAbove: Bool {
        hasOlderHistory || messages.count >= limit
    }

    /// One message, with everything the bubble cannot work out for itself.
    private func row(for entry: Entry, index: TranscriptIndex) -> some View {
        let message = entry.message
        let quoted = index.quoted.content(for: message)

        return MessageBubble(
            message: message,
            sender: index.sender(of: message),
            mentions: index.mentions(in: message),
            mentionCandidates: index.mentionCandidates,
            isOwn: entry.isOwn,
            isFirstInGroup: entry.isFirstInGroup,
            isLastInGroup: entry.isLastInGroup,
            isHighlighted: session.highlightedMessage == message.name,
            spaceName: spaceName,
            threadReplyCount: index.replyCount(of: message),
            newReplyCount: index.unreadReplyCount(of: message),
            quoted: quoted,
            onOpenThread: isThreaded ? { openThread(message) } : nil,
            onReply: { startReply(to: message, index: index) },
            // A reply's original is somewhere in this conversation, so the transcript can
            // reach it itself. A forward's is not, and the block draws its own way there.
            onOpenQuoted: quoted?.replyPreview
                .map { preview in { openQuoted(preview, index: index) } }
        )
    }

    private func startReply(to message: CachedMessage, index: TranscriptIndex) {
        replyTarget = ReplyTarget(
            message: message,
            authorName: index.quoted.authorName(of: message)
        )
    }

    /// Goes to the message a reply is quoting.
    ///
    /// In a threaded space a quoted reply is not in the transcript at all, so the way
    /// to it is its thread rather than a scroll position that does not exist. A quote of
    /// something older than the window is not in the transcript either — but that one is
    /// reachable, and asking for the jump is what opens the window onto it.
    private func openQuoted(_ preview: QuotedMessagePreview, index: TranscriptIndex) {
        let original = index.quoted.messagesByName[preview.messageName]
        if isThreaded, original?.isThreadReply == true, let threadName = original?.threadName {
            session.openThread(threadName)
            session.jumpInThread(to: preview.messageName)
        } else {
            session.jump(to: preview.messageName)
        }
    }

    private func openThread(_ message: CachedMessage) {
        // Chat assigns every message a thread, so a root with no replies yet is
        // still a valid target — replying to it starts the thread.
        guard let threadName = message.threadName else { return }
        session.openThread(threadName)
    }

    // MARK: - Grouping

    /// A message plus its position within a run from the same sender.
    private struct Entry {
        let message: CachedMessage
        let isOwn: Bool
        let isFirstInGroup: Bool
        let isLastInGroup: Bool
    }

    private struct DayGroup {
        let day: Date
        let entries: [Entry]
    }

    /// In a fully threaded space, replies belong to the thread pane, not the main
    /// flow — otherwise every reply appears twice and the room becomes unreadable.
    /// Grouped and unthreaded spaces stay flat, matching Chat's own rendering.
    private var visibleMessages: [CachedMessage] {
        guard isThreaded else { return messages }
        return messages.filter { !$0.isThreadReply }
    }

    /// Messages bucketed by day, then annotated with sender-run position.
    ///
    /// Written imperatively: the equivalent chained `Dictionary(grouping:)` and
    /// `map`/`sorted` pipeline exceeds the type checker's time budget and fails
    /// to compile.
    private var days: [DayGroup] {
        let calendar = Calendar.current
        var buckets: [Date: [CachedMessage]] = [:]

        for message in visibleMessages {
            let timestamp = message.createTime ?? Date.distantPast
            buckets[calendar.startOfDay(for: timestamp), default: []].append(message)
        }

        var result: [DayGroup] = []
        for (day, items) in buckets {
            let ordered = items.sorted { lhs, rhs in
                let left = lhs.createTime ?? Date.distantPast
                let right = rhs.createTime ?? Date.distantPast
                return left < right
            }
            result.append(DayGroup(day: day, entries: annotate(ordered)))
        }
        return result.sorted { $0.day < $1.day }
    }

    /// A run breaks on a sender change, or on a gap long enough that the messages
    /// are no longer one thought.
    private func annotate(_ ordered: [CachedMessage]) -> [Entry] {
        let groupingWindow: TimeInterval = 5 * 60
        var entries: [Entry] = []

        for (index, message) in ordered.enumerated() {
            let previous = index > 0 ? ordered[index - 1] : nil
            let next = index < ordered.count - 1 ? ordered[index + 1] : nil

            let startsRun = previous.map { earlier in
                earlier.senderName != message.senderName
                    || gap(from: earlier, to: message) > groupingWindow
            } ?? true

            let endsRun = next.map { later in
                later.senderName != message.senderName
                    || gap(from: message, to: later) > groupingWindow
            } ?? true

            entries.append(
                Entry(
                    message: message,
                    isOwn: session.isOwnMessage(message),
                    isFirstInGroup: startsRun,
                    isLastInGroup: endsRun
                )
            )
        }
        return entries
    }

    private func gap(from earlier: CachedMessage, to later: CachedMessage) -> TimeInterval {
        let start = earlier.createTime ?? Date.distantPast
        let end = later.createTime ?? Date.distantPast
        return end.timeIntervalSince(start)
    }
}

/// Everything a transcript row needs looked up, resolved once per body evaluation.
///
/// These were computed properties on the view, which reads innocently and is not: a
/// computed property called from the per-row builder is *recomputed for every row*, so
/// drawing the transcript rebuilt a dictionary over every cached message and every
/// directory row once per bubble. That is O(rows × cache) of pure allocation on every
/// body evaluation — and a body evaluation happens whenever anything the view observes
/// changes, including each new row the lazy stack builds while scrolling.
///
/// A snapshot rather than a live view of the cache, which is what the callers want: the
/// closures a row hands to its bubble fire on a click, and they should answer about the
/// transcript the reader clicked in.
private struct TranscriptIndex {
    let quoted: QuotedMessageResolver
    /// Who the composer's `@` can reach in this conversation.
    let mentionCandidates: [MentionCandidate]
    /// Replies per thread, and how many of them are unread. Both read from the thread
    /// rows: the store maintains them over the whole space, where the transcript can only
    /// see its own window, and a reply count that shrank as the reader scrolled would be
    /// worse than no count at all. Empty where replies are already in the transcript and
    /// the numbers would describe nothing.
    private let replyCounts: [String: Int]
    private let unreadReplyCounts: [String: Int]
    private let usersByID: [String: CachedUser]

    init(
        users: [CachedUser],
        messages: [CachedMessage],
        threads: [CachedThread],
        mentionableIDs: [String],
        isThreaded: Bool
    ) {
        let usersByID = Dictionary(
            users.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Every message the transcript has in hand, replies included — a quote can point
        // at one even in a threaded space, where replies are not in the transcript. A
        // quote reaching past the window falls back to the snapshot the server sent with
        // it; see ``QuotedMessageResolver``.
        let messagesByName = Dictionary(
            messages.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        self.usersByID = usersByID
        quoted = QuotedMessageResolver(messagesByName: messagesByName, usersByID: usersByID)
        mentionCandidates = MentionCandidate.list(for: mentionableIDs, users: usersByID)

        guard isThreaded else {
            replyCounts = [:]
            unreadReplyCounts = [:]
            return
        }

        var replies: [String: Int] = [:]
        var unread: [String: Int] = [:]
        for thread in threads {
            if thread.replyCount > 0 { replies[thread.name] = thread.replyCount }
            if thread.unreadReplyCount > 0 { unread[thread.name] = thread.unreadReplyCount }
        }
        replyCounts = replies
        unreadReplyCounts = unread
    }

    func sender(of message: CachedMessage) -> CachedUser? {
        guard let id = message.senderName else { return nil }
        return usersByID[id]
    }

    /// Display names of the people a message mentions, keyed by user resource name.
    ///
    /// People the directory has not answered for yet are left out rather than named
    /// "Unknown" — see ``ChatTextRenderer/body(formatted:plain:mentions:)`` for what a
    /// missing name costs.
    func mentions(in message: CachedMessage) -> [String: String] {
        var resolved: [String: String] = [:]
        for id in message.mentionedUserIDs {
            guard let name = usersByID[id]?.displayName, !name.isEmpty else { continue }
            resolved[id] = name
        }
        return resolved
    }

    func replyCount(of message: CachedMessage) -> Int {
        guard let thread = message.threadName else { return 0 }
        return replyCounts[thread] ?? 0
    }

    func unreadReplyCount(of message: CachedMessage) -> Int {
        guard let thread = message.threadName else { return 0 }
        return unreadReplyCounts[thread] ?? 0
    }
}

/// Centred date pill separating days.
private struct DayDivider: View {
    let day: Date

    var body: some View {
        HStack {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
                .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Messages from \(label)")
    }

    private var label: String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
