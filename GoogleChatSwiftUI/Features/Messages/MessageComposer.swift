import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Message input with file attachment.
///
/// Uses `TextField` with `.vertical` axis rather than `TextEditor`: it grows with
/// content, respects the send-on-Return convention, and does not need an
/// `NSViewRepresentable` wrapper.
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
                    .onSubmit(send)
                    // Escape drops the reply this message was aimed at, which is the
                    // only way out that does not involve sending it.
                    .onKeyPress(.escape) {
                        guard replyTarget != nil else { return .ignored }
                        onCancelReply()
                        return .handled
                    }

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

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let staged = attachments
        // Cleared optimistically to match the local echo; the send path preserves the
        // text in a flagged placeholder if it fails, so nothing is lost.
        text = ""
        attachments = []
        errorMessage = nil
        onSend(trimmed, staged)
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
