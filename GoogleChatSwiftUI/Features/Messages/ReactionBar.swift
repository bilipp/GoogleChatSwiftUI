import SwiftUI

/// Emoji reaction chips under a message, plus an add-reaction button.
struct ReactionBar: View {
    let reactions: [CachedReaction]
    /// The user's most-used emoji, seeded with defaults until they have history.
    let suggestions: [String]
    let onToggle: (String) -> Void

    @State private var isPickerPresented = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sorted, id: \.key) { reaction in
                chip(for: reaction)
            }
            addButton
        }
        .padding(.top, 2)
    }

    /// Stable ordering so chips don't reshuffle as counts change.
    private var sorted: [CachedReaction] {
        reactions.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.emoji < rhs.emoji
        }
    }

    private func chip(for reaction: CachedReaction) -> some View {
        Button {
            onToggle(reaction.emoji)
        } label: {
            HStack(spacing: 3) {
                Text(reaction.emoji).font(.caption)
                if reaction.count > 1 {
                    Text("\(reaction.count)")
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                reaction.reactedByMe ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                     : AnyShapeStyle(.quaternary),
                in: .capsule
            )
            .overlay {
                if reaction.reactedByMe {
                    Capsule().strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(reaction.reactedByMe ? "Remove your reaction" : "React with \(reaction.emoji)")
        .accessibilityLabel(
            "\(reaction.emoji), \(reaction.count) reaction\(reaction.count == 1 ? "" : "s")"
                + (reaction.reactedByMe ? ", including yours" : "")
        )
    }

    private var addButton: some View {
        Button {
            isPickerPresented = true
        } label: {
            Image(systemName: "face.smiling")
                .font(.caption)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Add reaction")
        .accessibilityLabel("Add reaction")
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            picker
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(suggestions, id: \.self) { emoji in
                    Button {
                        isPickerPresented = false
                        onToggle(emoji)
                    } label: {
                        Text(emoji)
                            .font(.title3)
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("React with \(emoji)")
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)

            Divider()

            EmojiPicker { emoji in
                isPickerPresented = false
                onToggle(emoji)
            }
        }
    }
}
