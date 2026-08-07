import SwiftUI

/// The list of people shown above the field while an `@name` is being typed.
///
/// The same construction as ``EmojiSuggestionList``, and for the same reasons — not a
/// `Menu` or a popover, because both take key focus on macOS and this has to stay open
/// while the user keeps typing into the field behind it; rows are tap gestures rather
/// than buttons so a click cannot pull first responder out of the composer.
///
/// Wider rows than the emoji list, and taller ones, because a face is what people
/// actually scan for when picking a colleague out of a room.
struct MentionSuggestionList: View {
    let matches: [MentionCandidate]
    let selection: Int
    let onHighlight: (Int) -> Void
    let onPick: (MentionCandidate) -> Void

    /// Fixed rather than measured, so the list's own height is arithmetic instead of a
    /// negotiation with the scroll view inside it.
    private static let rowHeight: CGFloat = 34

    /// Rows on screen at once. The composer grows upwards to make room, and past six
    /// that starts eating the transcript, so the rest scroll.
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
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator)
        }
        .shadow(radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People to mention")
    }

    private func row(_ match: MentionCandidate, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            // "Everyone" is not a person and should not wear a person's face; the
            // initials circle would say "A" and mean nothing.
            if match.isEveryone {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.gradient, in: .circle)
            } else {
                Avatar(name: match.displayName, photoURL: match.photoURL, size: 24)
            }

            Text("@\(match.displayName)")
                .font(.callout)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if match.isEveryone {
                Text("Notifies the whole space")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

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
        .accessibilityLabel(
            match.isEveryone ? "Mention everyone in the space" : "Mention \(match.displayName)"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    MentionSuggestionList(
        matches: [
            MentionCandidate(userName: "users/1", displayName: "Ada Lovelace", photoURL: nil),
            MentionCandidate(userName: "users/2", displayName: "Grace Hopper", photoURL: nil),
            .everyone,
        ],
        selection: 0,
        onHighlight: { _ in },
        onPick: { _ in }
    )
    .padding(40)
}
