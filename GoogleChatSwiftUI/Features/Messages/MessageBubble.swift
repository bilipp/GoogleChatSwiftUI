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
    /// Display names of users mentioned in this message, for highlighting.
    let mentionNames: [String]
    /// Who can be mentioned in this conversation, so an edit can re-encode the names
    /// in the draft. Without it, correcting a typo in a message that mentions someone
    /// posts their name back as prose and quietly un-mentions them.
    var mentionCandidates: [MentionCandidate] = []
    let isOwn: Bool
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    let spaceName: String
    /// Replies beneath this message's thread. Zero in unthreaded spaces.
    var threadReplyCount: Int = 0
    /// How many of those replies are unread.
    var newReplyCount: Int = 0
    /// The message this one quotes, resolved by the caller. Nil unless it is a reply.
    var quotedPreview: QuotedMessagePreview?
    /// Non-nil only in threaded spaces, where a thread pane makes sense.
    var onOpenThread: (() -> Void)?
    /// Starts an inline reply to this message. Nil where the surface has no composer
    /// to aim one at.
    var onReply: (() -> Void)?
    /// Jumps to the quoted message. Nil where it is not reachable from here.
    var onOpenQuoted: (() -> Void)?
    /// Set in the thread inspector, which is far narrower than the main transcript.
    var isCompact: Bool = false

    @State private var isEditing = false
    @State private var isEmojiPickerPresented = false
    @State private var draft = ""

    /// The opposite-side gutter that keeps own and other messages visibly aligned to
    /// their sides. In a narrow pane a fixed 48pt gutter eats the text instead.
    private var gutter: CGFloat { isCompact ? 12 : 48 }
    private var maxBubbleWidth: CGFloat { isCompact ? 380 : 520 }
    /// Cards need more room than prose; a 520pt cap makes multi-column cards unusable.
    private var maxContentWidth: CGFloat { isCompact ? 380 : 560 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOwn {
                Spacer(minLength: gutter)
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
                } else if !message.displayText.isEmpty || quotedPreview != nil {
                    bubble
                }

                // Cards render outside the bubble: they carry their own surface and
                // border, and nesting them in a coloured bubble reads as two boxes.
                ForEach(Array(message.cards.enumerated()), id: \.offset) { _, card in
                    CardView(card: card)
                        .contextMenu { contextMenu }
                }

                ForEach(Array(message.richLinks.enumerated()), id: \.offset) { _, link in
                    RichLinkChip(link: link)
                }

                if !message.attachments.isEmpty {
                    AttachmentList(attachments: message.attachments, isOwn: isOwn)
                }

                // Everything below is height-stable: nothing appears on hover, because
                // revealing controls inline reflows every message beneath the cursor.
                // The hover-only actions live in the context menu instead.
                if !message.reactions.isEmpty {
                    ReactionBar(
                        reactions: message.reactions,
                        suggestions: session.recentEmoji.suggestions
                    ) { emoji in
                        Task { await session.toggleReaction(emoji, on: message.name) }
                    }
                }

                if threadReplyCount > 0, let onOpenThread {
                    threadRepliesButton(onOpenThread)
                }

                if isLastInGroup {
                    metadata
                }

                if let reason = message.sendFailureReason {
                    failureBanner(reason)
                }
            }
            .frame(maxWidth: message.hasCards ? maxContentWidth : maxBubbleWidth,
                   alignment: isOwn ? .trailing : .leading)

            if !isOwn { Spacer(minLength: gutter) }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
        .padding(.vertical, isFirstInGroup ? 4 : 1)
        // Deliberately not `.combine`: combining children replaces the selectable
        // Text with a single synthetic element and drag-selection stops working.
        .accessibilityElement(children: .contain)
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

    /// Mention highlighting matches on display name, so the sender's own directory
    /// entry is irrelevant here — only the mentioned users' names matter.
    private var renderedBlocks: [ChatBlock] {
        guard !message.isDeleted, let raw = message.text, !raw.isEmpty else {
            return [.paragraph(AttributedString(message.displayText))]
        }
        return ChatTextRenderer.blocks(raw, mentionNames: mentionNames, isOwn: isOwn)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Above the reply's own text, as in the web client: the quote is what the
            // message is answering, so it has to be read first.
            if let quotedPreview {
                QuotedMessageChip(
                    preview: quotedPreview,
                    isOwn: isOwn,
                    onOpen: onOpenQuoted
                )
            }

            if !message.displayText.isEmpty {
                FormattedMessageText(blocks: renderedBlocks, isOwn: isOwn)
                    .font(.body)
                    .italic(message.isDeleted)
                    .foregroundStyle(foreground)
                    // Selectable text claims right-click for the system's own text menu,
                    // so our menu is reachable from the padding around it rather than
                    // the glyphs. The two cannot coexist on one view; selection wins
                    // here because reading and quoting part of a message matters more
                    // than menu reach.
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(background, in: shape)
        // Without an explicit hit shape the padding is not hit-testable, and
        // right-clicks fall straight through the bubble.
        .contentShape(shape)
        .contextMenu { contextMenu }
        .opacity(message.isPending ? 0.55 : 1)
        .popover(isPresented: $isEmojiPickerPresented, arrowEdge: .bottom) {
            EmojiPicker { emoji in
                isEmojiPickerPresented = false
                Task { await session.toggleReaction(emoji, on: message.name) }
            }
        }
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

    /// Shown only when a thread actually exists, since a reply count is real
    /// information rather than an affordance. Starting a new thread is a context-menu
    /// action so it costs no vertical space.
    private func threadRepliesButton(_ open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption2)
                Text(threadReplyCount == 1 ? "1 reply" : "\(threadReplyCount) replies")
                    .font(.caption.weight(newReplyCount > 0 ? .semibold : .medium))
                // The unread replies are behind this button and nowhere else on
                // screen, so the count belongs where the way in is.
                if newReplyCount > 0 {
                    Text("\(newReplyCount) new")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: .capsule)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.top, 1)
        .accessibilityLabel(threadButtonDescription)
    }

    private var threadButtonDescription: String {
        let replies = "Open thread, \(threadReplyCount) replies"
        guard newReplyCount > 0 else { return replies }
        return "\(replies), \(newReplyCount) unread"
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
        // Continuation rows show no inline timestamp, so the menu carries the full
        // one — otherwise the exact time of most messages would be unreachable.
        if let created = message.createTime {
            Text(created.formatted(date: .abbreviated, time: .standard))
        }

        if !message.isDeleted && !message.isPending {
            Menu("Add Reaction") {
                ForEach(session.recentEmoji.suggestions, id: \.self) { emoji in
                    Button(emoji) {
                        Task { await session.toggleReaction(emoji, on: message.name) }
                    }
                }
                Divider()
                // A context menu can't host the grid picker, so this opens it as a
                // popover anchored on the bubble.
                Button("More…") { isEmojiPickerPresented = true }
            }

            // Two kinds of reply, listed in the order they cost the reader: quoting
            // answers one message in the conversation everyone is already reading,
            // while a thread moves the discussion somewhere they have to go and find.
            //
            // Both are inside the gate above for the same reason reactions are: a
            // quote has to name the message it answers, and a message still in flight
            // has no server-assigned name to give.
            if let onReply {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply() }
            }

            if let onOpenThread {
                Button(
                    threadReplyCount > 0 ? "Open Thread" : "Reply in Thread",
                    systemImage: "bubble.left.and.bubble.right"
                ) {
                    onOpenThread()
                }
            }
        }

        Divider()

        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.summaryText, forType: .string)
        }

        // Absent rather than disabled for a message still in flight: it has no
        // server-assigned name yet, so there is no link to copy for a second or two,
        // and a greyed-out row would be explaining a state that is already over.
        if let messageLink {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(messageLink.absoluteString, forType: .string)
            }
            .help("Copy a chat.google.com link to this message")
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

    /// Chat's own permalink for this message.
    ///
    /// Built rather than fetched: no field on the `Message` resource carries it, and
    /// nothing in the API returns one. The shape is Chat's, though — see
    /// ``ChatDeepLink`` — so a link copied here opens the message in a colleague's
    /// browser, and back in this app when it comes home again.
    private var messageLink: URL? {
        guard !message.isPending else { return nil }
        return ChatDeepLink.messageURL(
            for: message.name,
            spaceURI: message.space?.spaceUri,
            spaceType: message.space?.spaceType
        )
    }

    /// Saves the edit, re-encoding whatever the draft still mentions.
    ///
    /// Chat renders a mention back into `text` as the plain name, so an edited message
    /// arrives here as "@Ada Lovelace" with the markup gone. Sending that back as-is
    /// would post it as prose, and the mention would disappear from a message that had
    /// one — visible to nobody, least of all the person who stopped being notified.
    /// The names are therefore encoded again on the way out, by the same rule the
    /// composer uses.
    ///
    /// The edit field itself offers no completion, so a *new* mention has to be typed
    /// out in full to be recognised.
    private func saveEdit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !text.isEmpty, text != message.text else { return }
        Task {
            await session.edit(
                messageName: message.name,
                newText: text,
                mentions: mentionCandidates
            )
        }
    }

    private var accessibilityDescription: String {
        let who = isOwn ? "You" : senderName
        let time = message.createTime?.formatted(date: .omitted, time: .shortened) ?? ""
        // Stripped, because VoiceOver reading "asterisk shipped asterisk" aloud is
        // worse than losing the emphasis.
        return "\(who) at \(time): \(ChatTextRenderer.plainText(message.summaryText))"
    }
}
