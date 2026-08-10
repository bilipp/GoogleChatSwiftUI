import SwiftData
import SwiftUI

/// Every thread in a space, newest activity first, with the unread ones marked.
///
/// This is the only route to an unread reply. A threaded space keeps replies out of
/// the main transcript, so a reply that arrives while you are elsewhere leaves no
/// mark anywhere you would look: the sidebar badge clears the moment you open the
/// space, and the transcript never showed the reply in the first place.
///
/// Opens filtered to unread when there is any, because that is what brought the user
/// here. The filter is a control, not a mode — the empty state offers the way out.
struct ThreadListPane: View {
    @Environment(ChatSessionModel.self) private var session
    @Query private var threads: [CachedThread]
    @Query private var users: [CachedUser]

    private let spaceName: String

    @State private var showsUnreadOnly = false
    @State private var didChooseInitialFilter = false

    init(spaceName: String) {
        self.spaceName = spaceName
        _threads = Query(
            filter: #Predicate<CachedThread> { $0.space?.name == spaceName },
            sort: [SortDescriptor(\CachedThread.lastActivityTime, order: .reverse)]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !threads.isEmpty { filterBar }
            Divider()
            content
        }
        .frame(minWidth: 320)
        .task {
            // Once per space: reopening the panel should respect a filter the user
            // has since changed, not reset it under them.
            if !didChooseInitialFilter {
                showsUnreadOnly = unreadCount > 0
                didChooseInitialFilter = true
            }
            // A thread read on chat.google.com is the one case where the local mark
            // is behind. Checked here, where the answer is about to be shown.
            await session.refreshThreadReadStates(in: spaceName)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Threads").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if unreadCount > 0 {
                Button("Mark All Read") {
                    Task { await session.markAllThreadsRead(in: spaceName) }
                }
                .controlSize(.small)
                .help("Clear the unread mark on every thread here")
            }
            Button {
                session.closeThreadInspector()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close threads")
            .accessibilityLabel("Close threads")
        }
        .padding(12)
        .background(.bar)
    }

    private var subtitle: String {
        if unreadCount > 0 {
            return unreadCount == 1 ? "1 unread" : "\(unreadCount) unread"
        }
        return threads.count == 1 ? "1 thread" : "\(threads.count) threads"
    }

    private var filterBar: some View {
        Picker("Show", selection: $showsUnreadOnly) {
            Text("All").tag(false)
            Text(unreadCount > 0 ? "Unread (\(unreadCount))" : "Unread").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if threads.isEmpty {
            ContentUnavailableView(
                "No Threads",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Replies to a message start a thread, and it will appear here.")
            )
            .frame(maxHeight: .infinity)
        } else if visibleThreads.isEmpty {
            ContentUnavailableView {
                Label("All Caught Up", systemImage: "checkmark.circle")
            } description: {
                Text("No threads here have unread replies.")
            } actions: {
                Button("Show All Threads") { showsUnreadOnly = false }
            }
            .frame(maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        // One dictionary for the whole list rather than one per row: `usersByID` was a
        // computed property reached for twice by every row drawn, so a pane of forty
        // threads rebuilt a table of every directory row eighty times a pass.
        let usersByID = Dictionary(
            users.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleThreads) { thread in
                    ThreadSummaryRow(
                        thread: thread,
                        starter: starter(of: thread, users: usersByID),
                        lastReplierName: lastReplierName(in: thread, users: usersByID)
                    ) {
                        session.openThread(thread.name, fromList: true)
                    }
                    Divider().padding(.leading, 12)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Data

    private var unreadCount: Int {
        threads.count(where: \.hasUnread)
    }

    private var visibleThreads: [CachedThread] {
        // Threads whose only message is a root that never got a reply are left out:
        // that message is already in the transcript, and listing it here would make
        // this a second, worse copy of the conversation rather than a thread index.
        let withReplies = threads.filter { $0.replyCount > 0 }
        guard showsUnreadOnly else { return withReplies }
        return withReplies.filter(\.hasUnread)
    }

    /// Who started the thread. Nil only for a thread whose root has not been cached.
    private func starter(
        of thread: CachedThread,
        users usersByID: [String: CachedUser]
    ) -> SenderIdentity? {
        guard let root = thread.root else { return nil }
        return SenderIdentity(message: root, sender: root.senderName.flatMap { usersByID[$0] })
    }

    /// Who spoke last, which is usually why the thread is worth opening.
    private func lastReplierName(
        in thread: CachedThread,
        users usersByID: [String: CachedUser]
    ) -> String? {
        let replies = thread.messages.filter { $0.isThreadReply && !$0.isDeleted }
        let newest = replies.max { lhs, rhs in
            (lhs.createTime ?? .distantPast) < (rhs.createTime ?? .distantPast)
        }
        guard let newest else { return nil }
        let identity = SenderIdentity(
            message: newest,
            sender: newest.senderName.flatMap { usersByID[$0] }
        )
        // Nil rather than a placeholder for a person the directory has not named: the
        // row already says who started the thread, and "· Unknown" reads worse than no
        // line at all. An app is named, because "App" is not standing in for an answer
        // that is on its way.
        return identity.resolvedName ?? (identity.isApp ? SenderIdentity.unnamedApp : nil)
    }
}

/// One thread as a row: who started it, what it says, and how far behind you are.
private struct ThreadSummaryRow: View {
    let thread: CachedThread
    let starter: SenderIdentity?
    let lastReplierName: String?
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(
                    name: starter?.resolvedName,
                    photoURL: starter?.photoURL,
                    size: 28,
                    isApp: starter?.isApp == true
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(starterName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let activity = thread.lastActivityTime {
                            Text(activity.formatted(.relative(presentation: .numeric)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Text(snippet)
                        .font(.callout)
                        .foregroundStyle(thread.hasUnread ? .primary : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(replyLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let lastReplierName {
                            Text("· \(lastReplierName)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if thread.unreadReplyCount > 0 { unreadBadge }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(isHovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var starterName: String {
        starter?.name ?? SenderIdentity.unnamedPerson
    }

    private var snippet: String {
        let text = thread.root?.summaryText ?? ""
        return text.isEmpty ? "Thread" : text
    }

    private var replyLabel: String {
        thread.replyCount == 1 ? "1 reply" : "\(thread.replyCount) replies"
    }

    private var unreadBadge: some View {
        Text("\(thread.unreadReplyCount) new")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: .capsule)
    }

    private var accessibilityDescription: String {
        var parts = ["Thread started by \(starterName)", snippet, replyLabel]
        if thread.unreadReplyCount > 0 {
            parts.append("\(thread.unreadReplyCount) unread")
        }
        return parts.joined(separator: ", ")
    }
}
