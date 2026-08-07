import SwiftData
import SwiftUI

/// Message history for one space, read from the cache.
///
/// `@Query` is rebuilt per space via `init`, so SwiftData does the filtering and
/// sorting in the store rather than the view loading everything and discarding most.
struct MessageListView: View {
    @Environment(ChatSessionModel.self) private var session
    @Query private var messages: [CachedMessage]
    /// Sender identity lives in `CachedUser`, not on the message, so one directory
    /// fetch names every message that person has ever sent — including ones already
    /// cached before the lookup happened.
    @Query private var users: [CachedUser]
    /// Thread index rows for this space, carrying the per-thread unread counts the
    /// space's own read mark cannot express.
    @Query private var threads: [CachedThread]

    private let spaceName: String
    private let spaceTitle: String
    private let isThreaded: Bool
    /// Threads here with unread replies, for the toolbar badge.
    private let unreadThreadCount: Int

    /// The message to keep still while older history loads in above it, captured as
    /// the request is made rather than after — by the time it returns, the row that
    /// was at the top is no longer the one to hold onto.
    @State private var historyAnchor: String?
    /// Bumped on send, which is the one moment the transcript should return to the
    /// end whether or not the reader was there.
    @State private var sendCount = 0
    /// The message the next send will quote, when the reader has chosen to reply to
    /// one. Held here rather than in the composer because the choice is made in the
    /// transcript and the send is aimed from here.
    @State private var replyTarget: ReplyTarget?

    init(spaceName: String, spaceTitle: String, isThreaded: Bool, unreadThreadCount: Int) {
        self.spaceName = spaceName
        self.spaceTitle = spaceTitle
        self.isThreaded = isThreaded
        self.unreadThreadCount = unreadThreadCount
        _messages = Query(
            filter: #Predicate<CachedMessage> { $0.space?.name == spaceName },
            sort: [SortDescriptor(\CachedMessage.createTime, order: .forward)]
        )
        _threads = Query(
            filter: #Predicate<CachedThread> { $0.space?.name == spaceName },
            sort: [SortDescriptor(\CachedThread.lastActivityTime, order: .reverse)]
        )
    }

    var body: some View {
        Group {
            if messages.isEmpty {
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
            } else {
                transcript
            }
        }
        .navigationTitle(spaceTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    historyAnchor = days.first?.entries.first?.message.name
                    Task { await session.loadOlderMessages(in: spaceName) }
                } label: {
                    Label("Load Older", systemImage: "arrow.up.circle")
                }
                .disabled(session.isLoading(spaceName))
                .help("Fetch older messages")
            }
            // Only where threads are a place of their own. In grouped and unthreaded
            // spaces replies are already in the transcript, so a thread index would
            // just be a second copy of what is on screen.
            ToolbarItem(placement: .primaryAction) {
                if isThreaded { threadsButton }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
                MessageComposer(
                    placeholder: replyTarget == nil ? "Message \(spaceTitle)" : "Reply",
                    isSending: session.isSending(spaceName),
                    replyTarget: replyTarget,
                    onCancelReply: { replyTarget = nil },
                    mentionCandidates: mentionCandidates
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
        // Members are fetched per space and only once per launch, so this is one call
        // the first time a conversation is opened rather than anything the sidebar
        // pays for — at 762 spaces, a members lookup each would dwarf the whole app.
        .task(id: spaceName) { await session.loadMentionableMembers(of: spaceName) }
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

    /// The conversation, positioned by `TranscriptScrollView`.
    ///
    /// Every scroll decision lives there rather than being spread across anchors and
    /// change handlers here: where to open, whether an arriving message should pull the
    /// view down, and how to stand still while older history is inserted above. The
    /// grouped days are computed once and handed over, since they are needed both as
    /// content and as the two identities that tell the scroll view which end moved.
    private var transcript: some View {
        @Bindable var session = session
        let groups = days

        return TranscriptScrollView(
            newestID: groups.last?.entries.last?.message.name,
            oldestID: groups.first?.entries.first?.message.name,
            horizontalPadding: 16,
            verticalPadding: 12,
            jumpTarget: $session.scrollTarget,
            historyAnchor: $historyAnchor,
            followTrigger: sendCount
        ) {
            ForEach(groups, id: \.day) { group in
                DayDivider(day: group.day)

                ForEach(group.entries, id: \.message.name) { entry in
                    row(for: entry)
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

    /// One message, with everything the bubble cannot work out for itself.
    private func row(for entry: Entry) -> some View {
        let message = entry.message
        let quotedPreview = quoted.preview(for: message)

        return MessageBubble(
            message: message,
            sender: sender(for: message),
            mentionNames: mentionNames(in: message),
            mentionCandidates: mentionCandidates,
            isOwn: entry.isOwn,
            isFirstInGroup: entry.isFirstInGroup,
            isLastInGroup: entry.isLastInGroup,
            spaceName: spaceName,
            threadReplyCount: threadReplyCount(for: message),
            newReplyCount: newReplyCount(for: message),
            quotedPreview: quotedPreview,
            onOpenThread: isThreaded ? { openThread(message) } : nil,
            onReply: { startReply(to: message) },
            onOpenQuoted: quotedPreview.map { preview in { openQuoted(preview) } }
        )
    }

    private var usersByID: [String: CachedUser] {
        Dictionary(users.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Who the composer's `@` can reach in this conversation.
    private var mentionCandidates: [MentionCandidate] {
        MentionCandidate.list(
            for: session.mentionableUserIDs(in: spaceName),
            users: usersByID
        )
    }

    /// Everything needed to say what a reply is quoting. Built from the same rows the
    /// transcript is already showing, so a quote of a cached message reads as it stands
    /// now rather than as the snapshot taken when it was quoted.
    private var quoted: QuotedMessageResolver {
        QuotedMessageResolver(messagesByName: messagesByName, usersByID: usersByID)
    }

    /// Every cached message in this space, replies included — a quote can point at one
    /// even in a threaded space, where replies are not in the transcript.
    private var messagesByName: [String: CachedMessage] {
        Dictionary(messages.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func startReply(to message: CachedMessage) {
        replyTarget = ReplyTarget(message: message, authorName: quoted.authorName(of: message))
    }

    /// Goes to the message a reply is quoting.
    ///
    /// In a threaded space a quoted reply is not in the transcript at all, so the way
    /// to it is its thread rather than a scroll position that does not exist.
    private func openQuoted(_ preview: QuotedMessagePreview) {
        let original = messagesByName[preview.messageName]
        if isThreaded, original?.isThreadReply == true, let threadName = original?.threadName {
            session.openThread(threadName)
        } else {
            session.scrollTarget = preview.messageName
        }
    }

    private func sender(for message: CachedMessage) -> CachedUser? {
        guard let id = message.senderName else { return nil }
        return usersByID[id]
    }

    private func mentionNames(in message: CachedMessage) -> [String] {
        message.mentionedUserIDs.compactMap { usersByID[$0]?.displayName }
    }

    private func threadReplyCount(for message: CachedMessage) -> Int {
        guard isThreaded, let thread = message.threadName else { return 0 }
        return replyCounts[thread] ?? 0
    }

    private func newReplyCount(for message: CachedMessage) -> Int {
        guard isThreaded, let thread = message.threadName else { return 0 }
        return unreadReplyCounts[thread] ?? 0
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

    /// Reply counts per thread, computed once rather than per row.
    private var replyCounts: [String: Int] {
        guard isThreaded else { return [:] }
        var counts: [String: Int] = [:]
        for message in messages where message.isThreadReply {
            guard let thread = message.threadName else { continue }
            counts[thread, default: 0] += 1
        }
        return counts
    }

    /// Unread replies per thread, read from the thread rows rather than recomputed:
    /// the store already maintains them, and the read marks they depend on live there.
    private var unreadReplyCounts: [String: Int] {
        guard isThreaded else { return [:] }
        var counts: [String: Int] = [:]
        for thread in threads where thread.unreadReplyCount > 0 {
            counts[thread.name] = thread.unreadReplyCount
        }
        return counts
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
