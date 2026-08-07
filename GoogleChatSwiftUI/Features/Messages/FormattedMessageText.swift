import SwiftUI

/// Lays out the blocks ``ChatTextRenderer`` parsed out of a message.
///
/// Inline styling travels inside each `AttributedString`, so all this view adds is
/// the furniture the block formats need: bullet glyphs, a quote rule, and a boxed
/// surface for fenced code. Text selection is inherited from the enclosing bubble
/// rather than set here, so a drag can run across several blocks.
struct FormattedMessageText: View {
    let blocks: [ChatBlock]
    let isOwn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Offset-keyed because blocks carry no identity of their own and the
            // whole list is rebuilt whenever the message text changes anyway.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: ChatBlock) -> some View {
        switch block {
        case .paragraph(let text):
            paragraph(text)
        case .bulletList(let items):
            bulletList(items)
        case .quote(let lines):
            quote(lines)
        case .codeBlock(let body):
            codeBlock(body)
        }
    }

    /// `fixedSize` vertically on every text block: inside a `VStack` that is itself
    /// width-capped by the bubble, SwiftUI will otherwise settle on a single
    /// truncated line for the longer blocks.
    private func paragraph(_ text: AttributedString) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletList(_ items: [AttributedString]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: "•")
                        // Fixed so the glyph column does not shift when an item
                        // starts with bold or monospaced text.
                        .font(.body)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("List, \(items.count) items")
    }

    private func quote(_ lines: [AttributedString]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // A shape stretches to the height the text settles on, which is what
            // keeps the rule the same length as the quotation.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isOwn ? AnyShapeStyle(.white.opacity(0.55)) : AnyShapeStyle(.tertiary))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quote")
    }

    private func codeBlock(_ body: String) -> some View {
        Text(body)
            .font(.system(.body, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // Matches the wash on inline code so the two read as one idea.
            .background(
                isOwn ? Color.white.opacity(0.18) : Color.primary.opacity(0.07),
                in: .rect(cornerRadius: 6)
            )
            .accessibilityLabel("Code block")
            .accessibilityValue(body)
    }
}

#Preview("Formatted message") {
    FormattedMessageText(
        blocks: ChatTextRenderer.blocks(
            """
            Shipping *today*: the _new_ parser, ~the old one~, and `inline code`.

            > It handles quotes
            > across several lines.

            - bullets with a dash
            * bullets with an asterisk
            - and *bold* inside an item

            ```
            let blocks = ChatTextRenderer.blocks(raw)
            ```

            Untouched: snake_case_name and https://example.com/a_b_c
            """
        ),
        isOwn: false
    )
    .padding(14)
    .frame(width: 420)
}
