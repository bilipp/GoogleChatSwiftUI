import SwiftData
import SwiftUI

/// One thread — its root message and every reply — with a composer scoped to it.
///
/// Shown in an inspector rather than nested inline: threads in an active space can
/// run long, and indenting them inside the main transcript makes both harder to
/// follow. This mirrors how Chat itself separates a thread from the room.
struct ThreadPane: View {
    @Environment(ChatSessionModel.self) private var session
    @Query private var messages: [CachedMessage]
    @Query private var users: [CachedUser]

    private let spaceName: String
    private let threadName: String

    /// Bumped on reply, so posting into a thread returns to the end of it.
    @State private var sendCount = 0
    /// The message in this thread the next reply will quote, if the reader picked one.
    @State private var replyTarget: ReplyTarget?

    init(spaceName: String, threadName: String) {
        self.spaceName = spaceName
        self.threadName = threadName
        _messages = Query(
            filter: #Predicate<CachedMessage> { $0.threadName == threadName },
            sort: [SortDescriptor(\CachedMessage.createTime, order: .forward)]
        )
    }

    var body: some View {
        // Once per body evaluation rather than once per row — see ``ThreadIndex``.
        let index = ThreadIndex(
            users: users,
            messages: messages,
            mentionableIDs: session.mentionableUserIDs(in: spaceName)
        )

        return VStack(spacing: 0) {
            header
            Divider()

            if messages.isEmpty {
                ContentUnavailableView(
                    "Thread Unavailable",
                    systemImage: "text.bubble",
                    description: Text("This thread's messages aren't cached yet.")
                )
                .frame(maxHeight: .infinity)
            } else {
                transcript(index)
            }

            MessageComposer(
                placeholder: "Reply in thread",
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
                        threadName: threadName,
                        replyingTo: target,
                        attachments: composed.attachments,
                        mentions: composed.mentions
                    )
                }
            }
        }
        .frame(minWidth: 380)
        // The transcript behind this pane has usually asked for the same members
        // already; the request is claimed per space, so the second ask is free.
        .task(id: spaceName) { await session.loadMentionableMembers(of: spaceName) }
    }

    /// No material of its own: the inspector column this pane fills is already a large
    /// glass surface, so the `.bar` that used to sit here read as a flat chrome band
    /// pasted over the glass rather than part of it. A rule carries the separation the
    /// band was there for, which is all it was earning.
    ///
    /// The two controls are recessed fills for the same reason the sidebar's search
    /// field is — see ``SidebarSearchField``. A glass button on a glass column has
    /// nothing to bend light through and renders as a bare glyph, so `.bordered` is
    /// what actually reads here, and the circular border shape is the affordance the
    /// old `xmark.circle.fill` was drawing by hand into an opaque disc.
    private var header: some View {
        HStack {
            // Only when there is a list behind this thread. A thread opened from the
            // transcript has nothing to go back to, and a back button that closed the
            // panel instead would be lying about where it leads.
            if session.canReturnToThreadList {
                Button {
                    session.closeThreadPane()
                } label: {
                    // `.backward` rather than `.left`: it points the way out of the
                    // panel, which flips with the writing direction.
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("Back to threads")
                .accessibilityLabel("Back to threads")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Thread").font(.headline)
                Text(replyLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                session.closeThreadInspector()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Close thread")
            .accessibilityLabel("Close thread")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var replyLabel: String {
        let replies = max(0, messages.count - 1)
        return replies == 1 ? "1 reply" : "\(replies) replies"
    }

    /// The same positioning as the main transcript, for the same reasons — see
    /// `TranscriptScrollView`. A thread opens on its newest reply, which is what the
    /// reader came for.
    private func transcript(_ index: ThreadIndex) -> some View {
        @Bindable var session = session

        return TranscriptScrollView(
            newestID: messages.last?.name,
            oldestID: messages.first?.name,
            horizontalPadding: 12,
            verticalPadding: 10,
            // Set only by a followed link naming one reply out of a thread's many. Every
            // other way in opens on the newest reply, which is what the reader came for.
            jumpTarget: $session.threadScrollTarget,
            followTrigger: sendCount
        ) {
            ForEach(Array(messages.enumerated()), id: \.element.name) { offset, message in
                // Marks where the replies the user had not seen begin. Opening
                // the thread has already cleared the unread mark by now, so this
                // is drawn from the position captured as it was opened.
                if message.name == firstUnreadName {
                    NewRepliesDivider()
                }

                // The root gets a separator beneath it so the distinction
                // between "the thing being discussed" and the discussion
                // stays visible while scrolling.
                MessageBubble(
                    message: message,
                    sender: index.sender(of: message),
                    mentions: index.mentions(in: message),
                    mentionCandidates: index.mentionCandidates,
                    isOwn: session.isOwnMessage(message),
                    isFirstInGroup: true,
                    isLastInGroup: true,
                    isHighlighted: session.highlightedMessage == message.name,
                    spaceName: spaceName,
                    quoted: index.quoted.content(for: message),
                    onReply: { startReply(to: message, index: index) },
                    // No jump to the quoted message: everything a *reply* here can quote is
                    // in this thread, already on screen. A forward is the exception — it can
                    // carry a message in from anywhere — and its own block offers the way
                    // there rather than relying on this.
                    isCompact: true
                )
                .id(message.name)

                if offset == 0 && messages.count > 1 {
                    Divider().padding(.vertical, 8)
                }
            }
        }
    }

    /// The first reply that had arrived since the user last read this thread.
    ///
    /// Own replies are skipped: coming back to a thread you answered should not
    /// announce your own message as the new thing to read.
    private var firstUnreadName: String? {
        guard let mark = session.openedThreadReadMark else { return nil }
        let first = messages.first { message in
            guard message.isThreadReply, !message.isDeleted else { return false }
            guard let created = message.createTime, created > mark else { return false }
            return !session.isOwnMessage(message)
        }
        return first?.name
    }

    /// The reply is posted into this thread whatever was quoted, root included —
    /// unlike the transcript, where quoting a root starts a new thread.
    private func startReply(to message: CachedMessage, index: ThreadIndex) {
        replyTarget = ReplyTarget(
            message: message,
            authorName: index.quoted.authorName(of: message),
            in: threadName
        )
    }
}

/// The lookups a thread's rows need, resolved once per body evaluation.
///
/// Smaller than the transcript's ``TranscriptIndex`` but built for the same reason:
/// reached for from the per-row builder, each of these rebuilt a dictionary over every
/// directory row once per bubble drawn.
private struct ThreadIndex {
    /// Resolves quotes against this thread's own messages, which is all a reply here
    /// can be quoting: Chat does not allow a quote to reach out of its thread.
    let quoted: QuotedMessageResolver
    /// The same people the main transcript offers: a thread reply goes to the space,
    /// so its `@` reaches everyone in the space rather than only those who have posted
    /// in this thread.
    let mentionCandidates: [MentionCandidate]
    private let usersByID: [String: CachedUser]

    init(users: [CachedUser], messages: [CachedMessage], mentionableIDs: [String]) {
        let usersByID = Dictionary(
            users.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.usersByID = usersByID
        quoted = QuotedMessageResolver(
            messagesByName: Dictionary(
                messages.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            usersByID: usersByID
        )
        mentionCandidates = MentionCandidate.list(for: mentionableIDs, users: usersByID)
    }

    func sender(of message: CachedMessage) -> CachedUser? {
        guard let id = message.senderName else { return nil }
        return usersByID[id]
    }

    /// Display names of the people a message mentions, keyed by user resource name,
    /// as in the transcript's own index.
    func mentions(in message: CachedMessage) -> [String: String] {
        var resolved: [String: String] = [:]
        for id in message.mentionedUserIDs {
            guard let name = usersByID[id]?.displayName, !name.isEmpty else { continue }
            resolved[id] = name
        }
        return resolved
    }
}

/// The line between what the user had already read and what they came here for.
private struct NewRepliesDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
            Text("New")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New replies below")
    }
}
