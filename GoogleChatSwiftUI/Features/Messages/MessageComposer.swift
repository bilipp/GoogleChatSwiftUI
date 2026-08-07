import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Message input with file attachment.
///
/// Uses `TextField` with `.vertical` axis rather than `TextEditor`: it grows with
/// content, respects the send-on-Return convention, and does not need an
/// `NSViewRepresentable` wrapper.
///
/// Typing `:smile` offers inline emoji completion; see ``EmojiShortcodeTrigger`` for
/// what that costs while the input is still a `TextField`.
struct MessageComposer: View {
    let placeholder: String
    let isSending: Bool
    /// The message being answered inline, shown above the field until it is sent or
    /// dropped. The owner of this state is also what `onSend` posts against, so the
    /// composer only has to display it and offer a way out.
    var replyTarget: ReplyTarget?
    var onCancelReply: () -> Void = {}
    let onSend: (String, [PendingAttachment]) -> Void

    @State private var text: String = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var isTargetedForDrop = false
    @State private var errorMessage: String?
    @State private var suggestions: [EmojiShortcode] = []
    @State private var selectedSuggestion = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let replyTarget {
                ReplyBanner(target: replyTarget, onCancel: onCancelReply)
            }

            if !attachments.isEmpty {
                AttachmentTray(attachments: attachments) { attachment in
                    attachments.removeAll { $0.id == attachment.id }
                }
            }

            // Part of the composer's layout rather than an overlay floating over the
            // transcript: the composer sits in a bottom `safeAreaInset`, which clips to
            // its own bounds, so a list drawn above the field was cut off at the top
            // edge. In the stack it grows the composer upwards instead, and every row
            // stays on screen.
            if !suggestions.isEmpty {
                EmojiSuggestionList(
                    matches: suggestions,
                    selection: selectedSuggestion,
                    onHighlight: { selectedSuggestion = $0 },
                    onPick: { complete(with: $0) }
                )
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .disabled(isSending)
                .help("Attach files")
                .accessibilityLabel("Attach files")

                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...12)
                    .focused($isFocused)
                    .padding(8)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
                    .onSubmit(submit)
                    .onChange(of: text) { refreshSuggestions() }
                    .onChange(of: isFocused) { if !isFocused { suggestions = [] } }
                    .onKeyPress(.upArrow) { moveSelection(by: -1) }
                    .onKeyPress(.downArrow) { moveSelection(by: 1) }
                    .onKeyPress(.tab) { completeSelection() ? .handled : .ignored }
                    // Escape unwinds one thing at a time, innermost first: the
                    // completion list, then the reply this message was aimed at.
                    .onKeyPress(.escape) {
                        if !suggestions.isEmpty {
                            suggestions = []
                            return .handled
                        }
                        guard replyTarget != nil else { return .ignored }
                        onCancelReply()
                        return .handled
                    }

                Button(action: sendNow) {
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
        }
        .padding(12)
        .background(.bar)
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4)
            }
        }
        // Dropping onto the composer is how most people expect to attach a file,
        // and it costs nothing on top of the picker path.
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            Task { await load(providers) }
            return true
        }
        .onAppear { isFocused = true }
        // Choosing "Reply" happens in the transcript, several rows away from here, so
        // the caret has to come to the composer rather than the user hunting for it.
        .onChange(of: replyTarget) { if replyTarget != nil { isFocused = true } }
    }

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !isSending
    }

    /// Return: takes the highlighted suggestion if the list is open, sends otherwise.
    ///
    /// Return is not intercepted through `onKeyPress` like the other completion keys,
    /// because `onSubmit` would still be reached and the message would go out behind
    /// the completion. Branching in one place keeps the key doing exactly one thing.
    private func submit() {
        guard !completeSelection() else { return }
        sendNow()
    }

    private func sendNow() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let staged = attachments
        // Cleared optimistically to match the local echo; the send path preserves the
        // text in a flagged placeholder if it fails, so nothing is lost.
        text = ""
        attachments = []
        suggestions = []
        errorMessage = nil
        onSend(trimmed, staged)
    }

    // MARK: - Emoji completion

    /// Re-reads the trailing `:fragment` after every edit.
    ///
    /// A closed `:shortcode:` substitutes outright and shows no list — the user has
    /// already said which emoji they meant.
    private func refreshSuggestions() {
        if let completed = EmojiShortcodeTrigger.completed(in: text) {
            text.replaceSubrange(completed.range, with: completed.emoji)
            suggestions = []
            return
        }

        guard let pending = EmojiShortcodeTrigger.pending(in: text) else {
            suggestions = []
            return
        }
        suggestions = EmojiShortcodeIndex.matches(for: pending.query)
        // The query changed, so any previous highlight refers to a row that is gone.
        selectedSuggestion = 0
    }

    /// Accepts the highlighted suggestion. Reports whether there was one to accept, so
    /// callers can fall through to whatever the key normally does.
    private func completeSelection() -> Bool {
        guard suggestions.indices.contains(selectedSuggestion) else { return false }
        return complete(with: suggestions[selectedSuggestion])
    }

    @discardableResult
    private func complete(with match: EmojiShortcode) -> Bool {
        guard let pending = EmojiShortcodeTrigger.pending(in: text) else {
            suggestions = []
            return false
        }
        // Trailing space because a completion is nearly always mid-sentence, and
        // typing one by hand after every emoji is the kind of friction people notice.
        text.replaceSubrange(pending.range, with: match.emoji + " ")
        suggestions = []
        return true
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let count = suggestions.count
        // Wrapping, so holding one arrow key reaches every row without a dead end.
        selectedSuggestion = ((selectedSuggestion + offset) % count + count) % count
        return .handled
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }
        stage(panel.urls.compactMap(PendingAttachment.init(contentsOf:)))
    }

    private func load(_ providers: [NSItemProvider]) async {
        var loaded: [PendingAttachment] = []
        for provider in providers {
            guard let url = try? await provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier
            ) as? Data,
                let fileURL = URL(dataRepresentation: url, relativeTo: nil),
                let attachment = PendingAttachment(contentsOf: fileURL)
            else { continue }
            loaded.append(attachment)
        }
        stage(loaded)
    }

    private func stage(_ candidates: [PendingAttachment]) {
        let (allowed, oversized) = candidates.reduce(
            into: ([PendingAttachment](), [String]())
        ) { result, attachment in
            if attachment.exceedsSizeLimit {
                result.1.append(attachment.filename)
            } else {
                result.0.append(attachment)
            }
        }

        attachments.append(contentsOf: allowed)
        // Rejected up front rather than after a long upload that ends in a server
        // error: Chat caps attachments at 200 MB.
        errorMessage = oversized.isEmpty
            ? nil
            : "Too large to send (200 MB limit): \(oversized.joined(separator: ", "))"
    }
}

/// What this message is answering, above the input.
///
/// Always visible while a reply is being composed rather than folded away: a quote is
/// the one thing about a message that cannot be inferred from the text being typed,
/// and sending one by accident is not undoable.
private struct ReplyBanner: View {
    let target: ReplyTarget
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(target.authorName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(target.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Stop replying (esc)")
            .accessibilityLabel("Stop replying to \(target.authorName)")
        }
        // The rule is a shape, and a shape takes every point of height it is offered —
        // here that is the whole detail pane. This holds the banner to the two lines
        // of text it actually contains.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }
}

/// Staged files above the input, each removable before sending.
private struct AttachmentTray: View {
    let attachments: [PendingAttachment]
    let onRemove: (PendingAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.symbol)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.filename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(attachment.byteCount)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            onRemove(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: 220)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 44)
    }
}

#Preview {
    MessageComposer(placeholder: "Message Engineering", isSending: false) { _, _ in }
        .frame(width: 600)
}

#Preview("Replying") {
    MessageComposer(
        placeholder: "Message Engineering",
        isSending: false,
        replyTarget: ReplyTarget(
            messageName: "spaces/A/messages/1",
            threadName: nil,
            authorName: "Ada Lovelace",
            preview: "Can we ship the parser today, or does it need another review pass?"
        )
    ) { _, _ in }
    .frame(width: 600)
}
