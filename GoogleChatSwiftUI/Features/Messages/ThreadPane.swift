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
                isSending: session.isSending(spaceName)
            ) { text in
                Task { await session.send(text, to: spaceName, threadName: threadName) }
            }
        }
        .frame(minWidth: 380)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thread").font(.headline)
                Text(replyLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                session.openThread(nil)
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

    /// Same bottom-anchoring as the main transcript, for the same reason: scrolling to
    /// the last message after layout produced a visible jump on every open.
    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(messages.enumerated()), id: \.element.name) { index, message in
                    // The root gets a separator beneath it so the distinction
                    // between "the thing being discussed" and the discussion
                    // stays visible while scrolling.
                    MessageBubble(
                        message: message,
                        sender: sender(for: message),
                        mentionNames: mentionNames(in: message),
                        isOwn: session.isOwnMessage(message),
                        isFirstInGroup: true,
                        isLastInGroup: true,
                        spaceName: spaceName,
                        isCompact: true
                    )
                    .id(message.name)

                    if index == 0 && messages.count > 1 {
                        Divider().padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
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
}
