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
        VStack(spacing: 0) {
            header

            if messages.isEmpty {
                ContentUnavailableView(
                    "Thread Unavailable",
                    systemImage: "text.bubble",
                    description: Text("This thread's messages aren't cached yet.")
                )
                .frame(maxHeight: .infinity)
            } else {
                transcript
            }

            MessageComposer(
                placeholder: "Reply in thread",
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

    private var header: some View {
        HStack {
            // Only when there is a list behind this thread. A thread opened from the
            // transcript has nothing to go back to, and a back button that closed the
            // panel instead would be lying about where it leads.
            if session.canReturnToThreadList {
                Button {
                    session.closeThreadPane()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
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
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close thread")
            .accessibilityLabel("Close thread")
        }
        .padding(12)
        .background(.bar)
    }

    private var replyLabel: String {
        let replies = max(0, messages.count - 1)
        return replies == 1 ? "1 reply" : "\(replies) replies"
    }

    /// The same positioning as the main transcript, for the same reasons — see
    /// `TranscriptScrollView`. A thread opens on its newest reply, which is what the
    /// reader came for.
    private var transcript: some View {
        TranscriptScrollView(
            newestID: messages.last?.name,
            oldestID: messages.first?.name,
            horizontalPadding: 12,
            verticalPadding: 10,
            followTrigger: sendCount
        ) {
            ForEach(Array(messages.enumerated()), id: \.element.name) { index, message in
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
                    sender: sender(for: message),
                    mentionNames: mentionNames(in: message),
                    mentionCandidates: mentionCandidates,
                    isOwn: session.isOwnMessage(message),
                    isFirstInGroup: true,
                    isLastInGroup: true,
                    spaceName: spaceName,
                    quotedPreview: quoted.preview(for: message),
                    onReply: { startReply(to: message) },
                    // No jump to the quoted message: everything a reply here can
                    // quote is in this thread, already on screen.
                    isCompact: true
                )
                .id(message.name)

                if index == 0 && messages.count > 1 {
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

    private var usersByID: [String: CachedUser] {
        Dictionary(users.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The same people the main transcript offers: a thread reply goes to the space,
    /// so its `@` reaches everyone in the space rather than only those who have posted
    /// in this thread.
    private var mentionCandidates: [MentionCandidate] {
        MentionCandidate.list(
            for: session.mentionableUserIDs(in: spaceName),
            users: usersByID
        )
    }

    /// Resolves quotes against this thread's own messages, which is all a reply here
    /// can be quoting: Chat does not allow a quote to reach out of its thread.
    private var quoted: QuotedMessageResolver {
        QuotedMessageResolver(
            messagesByName: Dictionary(
                messages.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            usersByID: usersByID
        )
    }

    /// The reply is posted into this thread whatever was quoted, root included —
    /// unlike the transcript, where quoting a root starts a new thread.
    private func startReply(to message: CachedMessage) {
        replyTarget = ReplyTarget(
            message: message,
            authorName: quoted.authorName(of: message),
            in: threadName
        )
    }

    private func sender(for message: CachedMessage) -> CachedUser? {
        guard let id = message.senderName else { return nil }
        return usersByID[id]
    }

    private func mentionNames(in message: CachedMessage) -> [String] {
        message.mentionedUserIDs.compactMap { usersByID[$0]?.displayName }
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
