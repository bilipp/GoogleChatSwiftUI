import SwiftUI

/// A single message rendered as a chat bubble.
///
/// Own messages sit right with an accent fill; others sit left with a neutral fill
/// and an avatar. Consecutive messages from one sender collapse into a block —
/// only the first shows an avatar and name, and only the last gets a tail — which
/// is what makes a long conversation scannable.
struct MessageBubble: View {
    @Environment(ChatSessionModel.self) private var session

    let message: CachedMessage
    /// Directory profile for the sender, when one has been resolved.
    let sender: CachedUser?
    let isOwn: Bool
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    let spaceName: String

    @State private var isEditing = false
    @State private var isHovering = false
    @State private var draft = ""

    private let maxBubbleWidth: CGFloat = 520

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOwn {
                Spacer(minLength: 48)
            } else {
                // Reserve the avatar's width on continuation rows so bubbles in a
                // block stay flush with each other.
                avatarSlot
            }

            VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
                if isFirstInGroup && !isOwn {
                    Text(senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                if isEditing {
                    editor
                } else {
                    bubble
                }

                if isLastInGroup || isHovering {
                    metadata
                }

                if let reason = message.sendFailureReason {
                    failureBanner(reason)
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: isOwn ? .trailing : .leading)

            if !isOwn { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
        .padding(.vertical, isFirstInGroup ? 4 : 1)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Pieces

    /// Falls back to the name stamped on the message, which is set for locally
    /// composed messages before any directory lookup has happened.
    private var senderName: String {
        sender?.displayName ?? message.senderDisplayName ?? "Unknown"
    }

    @ViewBuilder
    private var avatarSlot: some View {
        if isFirstInGroup {
            Avatar(name: senderName, photoURL: sender?.photoURL)
        } else {
            Color.clear.frame(width: 28, height: 1)
        }
    }

    private var bubble: some View {
        Text(message.displayText)
            .font(.body)
            .italic(message.isDeleted)
            .foregroundStyle(foreground)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background, in: shape)
            .opacity(message.isPending ? 0.55 : 1)
    }

    /// Square off the inner corner on the sender's side so a run of messages reads
    /// as one block rather than a stack of separate pills.
    private var shape: UnevenRoundedRectangle {
        let tight: CGFloat = 5
        let round: CGFloat = 16
        return UnevenRoundedRectangle(
            topLeadingRadius: isOwn ? round : (isFirstInGroup ? round : tight),
            bottomLeadingRadius: isOwn ? round : (isLastInGroup ? round : tight),
            bottomTrailingRadius: isOwn ? (isLastInGroup ? round : tight) : round,
            topTrailingRadius: isOwn ? (isFirstInGroup ? round : tight) : round
        )
    }

    private var background: AnyShapeStyle {
        if message.isDeleted { return AnyShapeStyle(.quaternary) }
        return isOwn
            ? AnyShapeStyle(Color.accentColor.gradient)
            : AnyShapeStyle(.quinary)
    }

    private var foreground: Color {
        if message.isDeleted { return .secondary }
        return isOwn ? .white : .primary
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            if message.isPending {
                Image(systemName: "clock")
                Text("Sending")
            } else if let created = message.createTime {
                Text(created.formatted(date: .omitted, time: .shortened))
            }
            if wasEdited {
                Text("· edited")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    private var wasEdited: Bool {
        guard let updated = message.lastUpdateTime, let created = message.createTime else {
            return false
        }
        return updated.timeIntervalSince(created) > 1
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...10)
                .frame(minWidth: 260)
            HStack {
                Button("Save", action: saveEdit)
                    .keyboardShortcut(.return, modifiers: [])
                Button("Cancel", role: .cancel) { isEditing = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .controlSize(.small)
        }
    }

    private func failureBanner(_ reason: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Not sent")
            Button("Retry") {
                Task {
                    await session.retrySend(
                        messageName: message.name,
                        text: message.text ?? "",
                        in: spaceName
                    )
                }
            }
            Button("Discard", role: .destructive) {
                Task { await session.discardFailedMessage(named: message.name) }
            }
        }
        .font(.caption)
        .controlSize(.small)
        .help(reason)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.displayText, forType: .string)
        }
        // Chat permits editing and deleting only your own messages, so offering
        // these on someone else's would be a guaranteed 403.
        if isOwn && !message.isDeleted && !message.isPending {
            Divider()
            Button("Edit") {
                draft = message.text ?? ""
                isEditing = true
            }
            Button("Delete", role: .destructive) {
                Task { await session.delete(messageName: message.name) }
            }
        }
    }

    private func saveEdit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !text.isEmpty, text != message.text else { return }
        Task { await session.edit(messageName: message.name, newText: text) }
    }

    private var accessibilityDescription: String {
        let who = isOwn ? "You" : senderName
        let time = message.createTime?.formatted(date: .omitted, time: .shortened) ?? ""
        return "\(who) at \(time): \(message.displayText)"
    }
}
