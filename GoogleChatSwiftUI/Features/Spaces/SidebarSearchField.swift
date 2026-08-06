import SwiftUI

/// Search field that lives inside the sidebar rather than in the window toolbar.
///
/// `.searchable` would place it in the toolbar, which is reserved for searching
/// *messages*. Conversation search belongs next to the conversation list it filters.
///
/// No `glassEffect` here: the sidebar is itself a large glass surface, and stacking
/// glass on glass is the visual-noise case the HIG warns about. A recessed capsule
/// reads correctly against it.
struct SidebarSearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { isFocused = false }

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: .capsule)
        .overlay {
            // Focus ring, since a plain field inside a capsule has no affordance of
            // its own once the system's text-field chrome is dropped.
            Capsule().strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 1.5)
        }
        .accessibilityLabel(placeholder)
    }
}
