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
    @Environment(\.modelContext) private var modelContext
    @Query private var threads: [CachedThread]

    private let spaceName: String

    @State private var showsUnreadOnly = false
    @State private var didChooseInitialFilter = false

    init(spaceName: String) {
        self.spaceName = spaceName
        // `replyCount > 0` belongs in the predicate, not in a filter over the result.
        // A threaded space gives every message a thread name, so most rows here are
        // one-message threads this list never shows — 20,200 of them in the busiest
        // space against none with a reply. Filtered in Swift, all 20,200 were
        // materialized as model objects on the main thread, and again on every save
        // the store made. Filtered in SQLite, they are never fetched.
        _threads = Query(
            filter: #Predicate<CachedThread> { $0.space?.name == spaceName && $0.replyCount > 0 },
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

    /// Bare of material, with a recessed close control — the same treatment, and for
    /// the same reasons, as ``ThreadPane``'s header. These two are one panel from the
    /// reader's side, and going back should not look like landing on a different
    /// surface.
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
                // Kept small: it is the secondary action here, and at full size the
                // capsule stands taller than the close button beside it.
                .controlSize(.small)
                .help("Clear the unread mark on every thread here")
            }
            Button {
                session.closeThreadInspector()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Close threads")
            .accessibilityLabel("Close threads")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        // The window's one directory snapshot, already keyed. This used to be a
        // `@Query` of every `CachedUser` plus a dictionary built over it here — a full
        // main-thread fetch on every write to the store, for three fields per row.
        // See ``DirectoryCache``.
        let usersByID = session.directory.profiles
        let rows = summaries(users: usersByID)

        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    let thread = row.thread
                    ThreadSummaryRow(
                        thread: thread,
                        starter: row.starter,
                        snippet: row.snippet,
                        lastReplierName: row.lastReplierName
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

    /// Threads whose only message is a root that never got a reply are already
    /// excluded by the query — that message is in the transcript, and listing it here
    /// would make this a second, worse copy of the conversation rather than a thread
    /// index. So this is only the unread filter.
    private var visibleThreads: [CachedThread] {
        guard showsUnreadOnly else { return threads }
        return threads.filter(\.hasUnread)
    }

    /// Everything the visible rows need from messages, in one fetch.
    ///
    /// Each row shows two messages: the thread's root — its starter and its snippet —
    /// and the newest reply, whose sender the row names. Both used to be found by
    /// filtering `thread.messages`, which faulted an entire thread's history per row to
    /// read two fields off two of its messages. Worse than slow: a to-many fault per row
    /// on the main context is one half of the race that crashed build 21, the other half
    /// being whatever the store actor was faulting at the same moment.
    ///
    /// ``CachedThread`` now records the two names, so this resolves both for every
    /// visible row in a single fetch. Threads whose tallies predate those columns fall
    /// back to the relationship — see ``root(of:in:)`` — which keeps a cache written by
    /// an older build readable until its next recompute rather than blank.
    private func summaries(users usersByID: [String: UserProfile]) -> [ThreadSummary] {
        let threads = visibleThreads
        let wanted = Set(threads.flatMap { [$0.rootMessageName, $0.lastReplyMessageName].compactMap { $0 } })
        var byName: [String: CachedMessage] = [:]
        if !wanted.isEmpty {
            let found = (try? modelContext.fetch(
                FetchDescriptor<CachedMessage>(predicate: #Predicate { wanted.contains($0.name) })
            )) ?? []
            byName = Dictionary(found.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }

        return threads.map { thread in
            ThreadSummary(
                thread: thread,
                starter: root(of: thread, in: byName).map { root in
                    SenderIdentity(message: root, sender: root.senderName.flatMap { usersByID[$0] })
                },
                snippet: snippet(of: root(of: thread, in: byName)),
                lastReplierName: lastReplierName(
                    thread.lastReplyMessageName.flatMap { byName[$0] },
                    users: usersByID
                )
            )
        }
    }

    /// The thread's opening message, from the batch — or through the relationship for a
    /// thread whose ``CachedThread/rootMessageName`` has never been computed.
    private func root(of thread: CachedThread, in byName: [String: CachedMessage]) -> CachedMessage? {
        if let name = thread.rootMessageName { return byName[name] }
        return thread.root
    }

    private func snippet(of root: CachedMessage?) -> String {
        let text = root?.summaryText ?? ""
        return text.isEmpty ? "Thread" : text
    }

    /// Who spoke last, which is usually why the thread is worth opening.
    private func lastReplierName(
        _ newest: CachedMessage?,
        users usersByID: [String: UserProfile]
    ) -> String? {
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

/// One row's worth of resolved data, so ``ThreadListPane/summaries(users:)`` can do the
/// message lookups once for the list rather than once per row.
private struct ThreadSummary: Identifiable {
    let thread: CachedThread
    let starter: SenderIdentity?
    let snippet: String
    let lastReplierName: String?

    var id: PersistentIdentifier { thread.persistentModelID }
}

/// One thread as a row: who started it, what it says, and how far behind you are.
private struct ThreadSummaryRow: View {
    let thread: CachedThread
    let starter: SenderIdentity?
    /// Resolved by the list, not read from `thread.root` here — see
    /// ``ThreadListPane/summaries(users:)``.
    let snippet: String
    let lastReplierName: String?
    let open: () -> Void

    @Environment(ChatSessionModel.self) private var session
    @State private var isHovering = false

    private func markRead() {
        let name = thread.name
        Task { await session.markThreadRead(name) }
    }

    private func markUnread() {
        let name = thread.name
        Task { await session.markThreadUnread(name) }
    }

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
        .contextMenu {
            if thread.hasUnread {
                Button("Mark as Read", systemImage: "envelope.open") { markRead() }
            } else if thread.replyCount > 0 {
                Button("Mark as Unread", systemImage: "envelope.badge") { markUnread() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var starterName: String {
        starter?.name ?? SenderIdentity.unnamedPerson
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
