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
                    placeholder: "Message \(spaceTitle)",
                    isSending: session.isSending(spaceName)
                ) { text, attachments in
                    Task { await session.send(text, to: spaceName, attachments: attachments) }
                }
            }
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

    /// Anchored at the bottom by the scroll view itself rather than by scrolling to
    /// the last message after the fact.
    ///
    /// The previous approach jumped in four separate ways: `onAppear` fired before the
    /// lazy stack had laid anything out so `scrollTo` was a no-op leaving the view at
    /// the top; the animated `scrollTo` on the last message changing fired while
    /// switching spaces; opening the thread inspector changed the width and the lazy
    /// stack lost its position on relayout; and a spinner inside the scroll content
    /// shifted every message down and back up as it came and went.
    private var transcript: some View {
        // A reader is back, but only to serve an explicit jump target set by opening a
        // search result. It never fires on content or selection changes, which is what
        // made the old imperative scrolling jump.
        ScrollViewReader { proxy in
            scrollContent
                .onChange(of: session.scrollTarget, initial: true) { _, target in
                    guard let target, messages.contains(where: { $0.name == target }) else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    // Cleared so returning to this conversation later opens at the
                    // bottom as usual rather than back at an old search hit.
                    session.scrollTarget = nil
                }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.day) { group in
                        DayDivider(day: group.day)

                        ForEach(group.entries, id: \.message.name) { entry in
                            MessageBubble(
                                message: entry.message,
                                sender: sender(for: entry.message),
                                mentionNames: mentionNames(in: entry.message),
                                isOwn: entry.isOwn,
                                isFirstInGroup: entry.isFirstInGroup,
                                isLastInGroup: entry.isLastInGroup,
                                spaceName: spaceName,
                                threadReplyCount: threadReplyCount(for: entry.message),
                                newReplyCount: newReplyCount(for: entry.message),
                                onOpenThread: isThreaded ? { openThread(entry.message) } : nil
                            )
                            .id(entry.message.name)
                        }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Start at the newest message, without a scroll animation to get there.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Hold that anchor through content growth and, critically, through the width
        // change when the thread inspector opens.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
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

    private var usersByID: [String: CachedUser] {
        Dictionary(users.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
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
