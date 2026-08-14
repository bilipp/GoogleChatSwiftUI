import SwiftUI

/// A message forwarded in from another conversation, drawn as a block of its own.
///
/// Not a chip, unlike ``QuotedMessageChip``, and the difference is the whole design. A reply
/// quotes something the reader can go and read; one truncated line is enough, and a taller
/// quote would make every reply read as two messages. A forward quotes something that may be
/// in a space this account cannot open — the copy that arrived with it is the only copy there
/// is — so it gets the room a message gets: full text, its formatting, its files.
///
/// Drawn *below* the bubble rather than inside it, for the reason cards and attachments are.
/// An own message's bubble is an accent fill, and a block of somebody else's words inside it
/// would be claiming they were said in that voice. Out here it sits on the transcript's own
/// background and reads the same whichever side sent it.
///
/// The rule down the leading edge is the same rule ``QuotedMessageChip`` and a `>` quotation
/// use, at the size this block needs: three ways of showing quoted words that all look like
/// one idea.
///
/// There is no timestamp anywhere in the block, deliberately. The only date Chat sends with a
/// forward is the quoted message's `lastUpdateTime`, which is its creation time *or* the time
/// of an edit with nothing to say which — so "Sent 12 August" would be wrong for every
/// original that had ever been edited, and there is no way to tell those apart. The message
/// that carries the forward has an honest timestamp of its own, right beneath.
struct ForwardedMessageCard: View {
    let forwarded: ForwardedMessage
    /// Goes to the original, where this account can reach it. Nil where it cannot — a forward
    /// out of a space nobody here is a member of has nowhere to go, and an affordance that
    /// silently does nothing is worse than none.
    var onOpenOriginal: (() -> Void)?
    /// Set in the thread inspector, which is far narrower than the main transcript.
    var isCompact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.5))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 5) {
                header
                if let author = forwarded.authorName {
                    Text(author)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !forwarded.body.isEmpty {
                    FormattedMessageText(blocks: blocks, isOwn: false)
                        .font(.body)
                        // Enabled here rather than inherited: this block is outside the
                        // bubble, which is where the app turns selection on, and forwarded
                        // text is the kind most likely to be quoted onward again.
                        .textSelection(.enabled)
                }

                ForEach(Array(forwarded.richLinks.enumerated()), id: \.offset) { _, link in
                    RichLinkChip(link: link)
                }

                if !forwarded.attachments.isEmpty {
                    AttachmentList(
                        attachments: forwarded.attachments,
                        isOwn: false,
                        previewLimit: previewLimit
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        // `.contain`, not `.combine`: combining replaces the selectable body with one
        // synthetic element and drag-selection inside the block stops working — the same
        // trap ``MessageBubble`` documents.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Where it came from, which is the one thing this block says that the message itself
    /// cannot. Named as the conversation was called at the time of forwarding; Chat supplies
    /// no name for a space it will not say anything else about either, and then the block
    /// says only that something was forwarded.
    @ViewBuilder
    private var header: some View {
        let label = Label {
            Text(sourceDescription)
        } icon: {
            Image(systemName: "arrowshape.turn.up.forward")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

        if let onOpenOriginal {
            Button(action: onOpenOriginal) { label }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Show the original message")
                .accessibilityLabel("Show the original of this forwarded message")
        } else {
            label
        }
    }

    private var sourceDescription: String {
        guard let title = forwarded.sourceTitle, !title.isEmpty else {
            return "Forwarded message"
        }
        return "Forwarded from \(title)"
    }

    private var blocks: [ChatBlock] {
        RenderedChatText.blocks(forwarded.body, mentions: forwarded.mentions, isOwn: false)
    }

    private var maxWidth: CGFloat { isCompact ? 360 : 500 }

    /// Inset by the rule, its gap and the block's own padding, so a forwarded picture stays
    /// inside the frame instead of pushing it wider than the bubbles around it.
    private var previewLimit: CGSize {
        CGSize(width: maxWidth - 40, height: 240)
    }

    private var accessibilityDescription: String {
        let origin = forwarded.sourceTitle.map { "from \($0)" } ?? "from another conversation"
        let author = forwarded.authorName.map { ", by \($0)" } ?? ""
        let body = RenderedChatText.plainText(forwarded.body.text)
        let count = forwarded.attachments.count
        let files = count == 0
            ? ""
            : " With \(count == 1 ? "1 attached file" : "\(count) attached files")."
        return "Forwarded message \(origin)\(author): \(body).\(files)"
    }
}

#Preview("Forwarded message") {
    VStack(alignment: .leading, spacing: 12) {
        ForwardedMessageCard(
            forwarded: ForwardedMessage(
                messageName: "spaces/B/messages/1.1",
                sourceSpaceName: "spaces/B",
                sourceTitle: "Univcc Rollout",
                authorName: "Ada Lovelace",
                body: ChatMessageBody(
                    text: "Could someone take *point* on the font swap?\n\n- Ships Thursday\n- Needs a design review first",
                    source: .formatted
                ),
                mentions: [:],
                attachments: [],
                richLinks: []
            ),
            onOpenOriginal: {}
        )

        ForwardedMessageCard(
            forwarded: ForwardedMessage(
                messageName: "spaces/C/messages/1.1",
                sourceSpaceName: nil,
                sourceTitle: nil,
                authorName: nil,
                body: ChatMessageBody(text: "No source, no way back to it.", source: .plain),
                mentions: [:],
                attachments: [],
                richLinks: []
            )
        )
    }
    .padding()
    .frame(width: 560)
}
