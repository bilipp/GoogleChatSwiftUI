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
    /// Steps the highlight through the results by ±1.
    var onMoveHighlight: (Int) -> Void = { _ in }
    /// Return: open whatever is highlighted.
    var onOpenHighlighted: () -> Void = {}
    /// Escape: clear the query, or give up focus if there is nothing to clear.
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                // The arrows drive the result list, not the insertion point. A
                // one-line query field has little use for caret keys, and reaching
                // for the mouse to pick a result would undo the point of a
                // keyboard-summoned search. `.handled` is what stops the field
                // from also moving the caret.
                .onKeyPress(.upArrow) { onMoveHighlight(-1); return .handled }
                .onKeyPress(.downArrow) { onMoveHighlight(1); return .handled }
                .onKeyPress(.escape) { onCancel(); return .handled }
                .onSubmit { onOpenHighlighted() }

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
