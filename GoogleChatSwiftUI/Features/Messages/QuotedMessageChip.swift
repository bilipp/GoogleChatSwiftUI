import SwiftUI

/// The message a reply is answering, shown at the top of the reply's own bubble.
///
/// Deliberately one line and quiet: the quote is context for what follows, and a
/// full-height copy of the original would make every reply read as two messages. It
/// borrows the rule-and-indent of ``FormattedMessageText``'s quote block, so a quoted
/// reply and a `>` quotation inside a message look like the same idea.
struct QuotedMessageChip: View {
    let preview: QuotedMessagePreview
    let isOwn: Bool
    /// Set where the original is reachable — the main transcript. Nil in the thread
    /// pane, where the quoted message is already on screen and there is nowhere to go.
    var onOpen: (() -> Void)?

    var body: some View {
        if let onOpen {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("Show quoted message from \(preview.authorName)")
                .accessibilityValue(preview.text)
                .help("Show the quoted message")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Quoting \(preview.authorName): \(preview.text)")
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(rule)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(preview.authorName)
                    .font(.caption.weight(.semibold))
                Text(preview.text)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(label)
        }
        .fixedSize(horizontal: false, vertical: true)
        // The bubble enables text selection, which would otherwise let a drag pick the
        // quote's text out as if it were part of the reply.
        .textSelection(.disabled)
    }

    /// Inside an own-message bubble the accent fill is already the background, so the
    /// quote is separated by opacity rather than by a colour that would disappear.
    private var rule: AnyShapeStyle {
        isOwn ? AnyShapeStyle(.white.opacity(0.55)) : AnyShapeStyle(.tertiary)
    }

    private var label: AnyShapeStyle {
        isOwn ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }
}

#Preview("Quoted reply") {
    VStack(alignment: .leading, spacing: 12) {
        QuotedMessageChip(
            preview: QuotedMessagePreview(
                messageName: "spaces/A/messages/1",
                authorName: "Ada Lovelace",
                text: "Can we ship the parser today, or does it need another review pass?"
            ),
            isOwn: false,
            onOpen: {}
        )
        .padding(14)
        .background(.quinary, in: .rect(cornerRadius: 16))

        QuotedMessageChip(
            preview: QuotedMessagePreview(
                messageName: "spaces/A/messages/1",
                authorName: "Ada Lovelace",
                text: "Can we ship the parser today?"
            ),
            isOwn: true
        )
        .padding(14)
        .background(Color.accentColor.gradient, in: .rect(cornerRadius: 16))
    }
    .padding()
    .frame(width: 420)
}
