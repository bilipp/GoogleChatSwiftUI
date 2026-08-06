import SwiftUI

/// Message input.
///
/// Uses `TextField` with `.vertical` axis rather than `TextEditor`: it grows with
/// content, respects the send-on-Return convention, and does not need an
/// `NSViewRepresentable` wrapper. Phase 7 replaces this with an `NSTextView` bridge
/// once @-mention autocomplete and paste-to-attach are needed.
struct MessageComposer: View {
    let placeholder: String
    let isSending: Bool
    let onSend: (String) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...12)
                .focused($isFocused)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .onSubmit(send)
                .accessibilityLabel(placeholder)

            Button(action: send) {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
            .accessibilityLabel("Send message")
        }
        .padding(12)
        .background(.bar)
        .onAppear { isFocused = true }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Cleared optimistically to match the local echo; the send path preserves the
        // text in a flagged placeholder if it fails, so nothing is lost.
        text = ""
        onSend(trimmed)
    }
}

#Preview {
    MessageComposer(placeholder: "Message Engineering", isSending: false, onSend: { _ in })
        .frame(width: 600)
}
