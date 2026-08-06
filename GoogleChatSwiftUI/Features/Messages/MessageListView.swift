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

    private let spaceName: String
    private let spaceTitle: String
    private let isThreaded: Bool

    init(spaceName: String, spaceTitle: String, isThreaded: Bool) {
        self.spaceName = spaceName
        self.spaceTitle = spaceTitle
        self.isThreaded = isThreaded
        _messages = Query(
            filter: #Predicate<CachedMessage> { $0.space?.name == spaceName },
            sort: [SortDescriptor(\CachedMessage.createTime, order: .forward)]
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
                ) { text in
                    Task { await session.send(text, to: spaceName) }
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.isLoading(spaceName) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                    }

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
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: messages.last?.name) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { scrollToBottom(proxy) }
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

    private func openThread(_ message: CachedMessage) {
        // Chat assigns every message a thread, so a root with no replies yet is
        // still a valid target — replying to it starts the thread.
        session.openThread(message.threadName)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        proxy.scrollTo(last.name, anchor: .bottom)
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
