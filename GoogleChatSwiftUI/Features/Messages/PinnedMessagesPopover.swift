import SwiftUI

/// The messages pinned in a space, read from Chat when the popover opens.
///
/// Read from Chat rather than the cache because a pinned message is often older than
/// the history downloaded so far. Choosing one goes through the deep-link path, which
/// fetches history until the message is on screen.
struct PinnedMessagesPopover: View {
    @Environment(ChatSessionModel.self) private var session

    let spaceName: String
    let dismiss: () -> Void

    @State private var messages: [ChatMessage]?

    var body: some View {
        Group {
            if let messages {
                if messages.isEmpty {
                    ContentUnavailableView("No Pinned Messages", systemImage: "pin.slash")
                } else {
                    list(messages)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 360, height: 320)
        .task(id: session.pinnedMessageNames[spaceName] ?? []) {
            messages = await session.pinnedMessages(in: spaceName)
        }
    }

    private func list(_ messages: [ChatMessage]) -> some View {
        let usersByID = session.directory.profiles
        return List(messages, id: \.name) { message in
            Button {
                open(message)
            } label: {
                row(message, usersByID: usersByID)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Unpin", systemImage: "pin.slash") {
                    Task { await session.setMessagePinned(false, messageName: message.name) }
                }
            }
        }
    }

    private func row(_ message: ChatMessage, usersByID: [String: UserProfile]) -> some View {
        let profile = message.sender?.name.flatMap { usersByID[$0] }
        let identity = SenderIdentity(
            resolvedName: profile?.displayName ?? message.sender?.displayName,
            photoURL: profile?.photoURL,
            isApp: profile?.isApp == true || message.sender?.type == .bot
        )
        return HStack(alignment: .top, spacing: 8) {
            Avatar(
                name: identity.resolvedName,
                photoURL: identity.photoURL,
                size: 22,
                isApp: identity.isApp
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(identity.name)
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    if let created = message.createTime {
                        Text(created.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(message.displayText)
                    .font(.callout)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    private func open(_ message: ChatMessage) {
        let link = ChatDeepLink(
            spaceName: spaceName,
            threadName: message.threadReply == true ? message.thread?.name : nil,
            messageName: message.name
        )
        dismiss()
        Task { await session.reveal(link) }
    }
}
