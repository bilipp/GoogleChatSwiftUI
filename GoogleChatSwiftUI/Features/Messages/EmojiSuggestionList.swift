import SwiftUI

/// The inline completion list shown above the field while a `:shortcode` is being typed.
///
/// Not a `Menu` or a popover: both take key focus on macOS, and this has to stay open
/// while the user keeps typing into the field behind it. Rows are tap gestures rather
/// than buttons for the same reason — clicking one must not pull first responder out
/// of the composer, or the completion would land in a field that has just lost focus.
struct EmojiSuggestionList: View {
    let matches: [EmojiShortcode]
    let selection: Int
    let onHighlight: (Int) -> Void
    let onPick: (EmojiShortcode) -> Void

    /// Row height, fixed rather than measured, so the list's own height is arithmetic
    /// instead of a negotiation with the scroll view inside it.
    private static let rowHeight: CGFloat = 30

    /// Rows on screen at once. The composer grows upwards to make room for the list, and
    /// past six rows that starts eating the transcript, so the rest scroll.
    private static let visibleRows = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                        row(match, isSelected: index == selection)
                            .frame(height: Self.rowHeight)
                            .contentShape(.rect)
                            .onTapGesture { onPick(match) }
                            // Following the pointer keeps one highlight on screen: a
                            // hover ring plus a separate keyboard selection reads as
                            // two cursors.
                            .onHover { if $0 { onHighlight(index) } }
                            .id(index)
                    }
                }
            }
            .scrollIndicators(.never)
            // The arrow keys can walk the selection past the visible rows, and a
            // highlight nobody can see is worse than no highlight at all.
            .onChange(of: selection) { proxy.scrollTo(selection) }
        }
        .frame(height: CGFloat(min(matches.count, Self.visibleRows)) * Self.rowHeight)
        .padding(4)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator)
        }
        .shadow(radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Emoji suggestions")
    }

    private func row(_ match: EmojiShortcode, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(match.emoji)
                .font(.title3)
            Text(match.label)
                .font(.callout)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(match.label) \(match.emoji)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    EmojiSuggestionList(
        matches: EmojiShortcodeIndex.matches(for: "smile"),
        selection: 0,
        onHighlight: { _ in },
        onPick: { _ in }
    )
    .padding(40)
}
