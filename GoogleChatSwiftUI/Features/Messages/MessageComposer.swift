import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the composer hands over on send.
///
/// A value rather than a widening list of closure parameters, because the mentions are
/// not a property of the text: they are what the send path needs in order to turn the
/// readable draft into the markup Chat wants, and they travel with it or not at all.
struct ComposedMessage {
    let text: String
    let attachments: [PendingAttachment]
    /// The people `text` mentions by name. See ``MentionEncoder``.
    let mentions: [MentionCandidate]
}

/// Message input with file attachment.
///
/// Uses `TextField` with `.vertical` axis rather than `TextEditor`: it grows with
/// content, respects the send-on-Return convention — Shift+Return breaks the line
/// instead — and does not need an `NSViewRepresentable` wrapper.
///
/// Typing `:smile` offers inline emoji completion and `@ada` offers the people in the
/// room; see ``EmojiShortcodeTrigger`` and ``MentionTrigger`` for what both cost while
/// the input is still a `TextField`.
struct MessageComposer: View {
    let placeholder: String
    let isSending: Bool
    /// The message being answered inline, shown above the field until it is sent or
    /// dropped. The owner of this state is also what `onSend` posts against, so the
    /// composer only has to display it and offer a way out.
    var replyTarget: ReplyTarget?
    var onCancelReply: () -> Void = {}
    /// Who `@` can reach here. Empty until the space's members have been resolved,
    /// which simply means the list stays shut rather than offering half a room.
    var mentionCandidates: [MentionCandidate] = []
    let onSend: (ComposedMessage) -> Void

    @State private var text: String = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var isTargetedForDrop = false
    @State private var errorMessage: String?
    @State private var suggestions: [CompletionSuggestion] = []
    @State private var selectedSuggestion = 0
    /// Mentions this draft has picked up, in the form they were written into the text.
    ///
    /// Kept beside the string rather than encoded into it, because the user has to be
    /// able to read and edit what they are about to send — `<users/123>` in the field
    /// would be neither. Deleting the name from the text is what un-mentions someone:
    /// the encoder only rewrites names it still finds.
    @State private var resolvedMentions: [MentionCandidate] = []
    /// Whether the Return being handled right now is a line break rather than a send.
    /// See ``submit()`` for why the two paths cannot be told apart any later than this.
    @State private var returnIsLineBreak = false
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
            completionList

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .disabled(isSending)
                .help("Attach files")
                .accessibilityLabel("Attach files")

                input

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
        // Pasting is the only way to send a screenshot that was never saved, and the
        // picker cannot reach one: there is no file to point it at.
        .modifier(ImagePasteHandler(isEnabled: isFocused && !isSending, onPaste: stage))
        .onAppear { isFocused = true }
        // Choosing "Reply" happens in the transcript, several rows away from here, so
        // the caret has to come to the composer rather than the user hunting for it.
        .onChange(of: replyTarget) { if replyTarget != nil { isFocused = true } }
    }

    /// Whichever list the trailing fragment opened, or nothing.
    ///
    /// `suggestions` only ever holds one kind at a time — the fragment is a
    /// `:shortcode` or an `@name`, never both — so one of these two is always empty,
    /// and the selection index means the same thing whichever is drawn.
    @ViewBuilder
    private var completionList: some View {
        let people = suggestions.compactMap(\.mention)
        let emoji = suggestions.compactMap(\.emoji)

        if !people.isEmpty {
            MentionSuggestionList(
                matches: people,
                selection: selectedSuggestion,
                onHighlight: { selectedSuggestion = $0 },
                onPick: { complete(withMention: $0) }
            )
        } else if !emoji.isEmpty {
            EmojiSuggestionList(
                matches: emoji,
                selection: selectedSuggestion,
                onHighlight: { selectedSuggestion = $0 },
                onPick: { complete(withEmoji: $0) }
            )
        }
    }

    /// The keys the composer answers to, layered onto ``textField``.
    ///
    /// Split from the field itself only because one chain holding both the styling and
    /// every key handler took the type checker past its budget.
    private var input: some View {
        textField
            // Shift+Return breaks the line instead of sending, the convention every
            // other chat client shares. Matched through `keys:` rather than as a single
            // key because that is the overload reporting which modifiers came with it.
            .onKeyPress(keys: [.return]) { press in
                // Recorded on every Return, including the plain one, so a line break
                // can never leave the flag standing for the send that follows it.
                returnIsLineBreak = press.modifiers.contains(.shift)
                guard returnIsLineBreak else { return .ignored }
                insertLineBreak()
                return .handled
            }
            .onKeyPress(.upArrow) { moveSelection(by: -1) }
            .onKeyPress(.downArrow) { moveSelection(by: 1) }
            .onKeyPress(.tab) { completeSelection() ? .handled : .ignored }
            // Escape unwinds one thing at a time, innermost first: the completion
            // list, then the reply this message was aimed at.
            .onKeyPress(.escape) {
                if !suggestions.isEmpty {
                    suggestions = []
                    return .handled
                }
                guard replyTarget != nil else { return .ignored }
                onCancelReply()
                return .handled
            }
    }

    private var textField: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...12)
            .focused($isFocused)
            .padding(8)
            .background(.quaternary, in: .rect(cornerRadius: 8))
            .onSubmit(submit)
            .onChange(of: text) { refreshSuggestions() }
            .onChange(of: isFocused) { if !isFocused { suggestions = [] } }
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
    /// A Shift+Return is turned away here for the same reason. Whether reporting that
    /// key `.handled` is enough on its own to keep `onSubmit` away has gone both ways
    /// in this file, and a message sent by accident cannot be recalled, so the line
    /// break says so outright instead of trusting the event to have been consumed.
    private func submit() {
        guard !returnIsLineBreak else { return }
        guard !completeSelection() else { return }
        sendNow()
    }

    /// Types a line break into the field by hand.
    ///
    /// Nothing inserts one for us: to a text field Return means "end editing", which is
    /// the very thing `onSubmit` reports. Going through the field editor puts the break
    /// at the caret — a plain `TextField` publishes no selection, so the fallback for an
    /// unexpected responder can only add the break at the end.
    private func insertLineBreak() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
            text.append("\n")
            return
        }
        editor.insertText("\n", replacementRange: editor.selectedRange())
    }

    private func sendNow() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let staged = attachments
        let mentions = resolvedMentions
        // Cleared optimistically to match the local echo; the send path preserves the
        // text in a flagged placeholder if it fails, so nothing is lost.
        text = ""
        attachments = []
        suggestions = []
        resolvedMentions = []
        errorMessage = nil
        onSend(ComposedMessage(text: trimmed, attachments: staged, mentions: mentions))
    }

    // MARK: - Completion

    /// Re-reads the trailing fragment after every edit.
    ///
    /// A closed `:shortcode:` substitutes outright and shows no list — the user has
    /// already said which emoji they meant. Otherwise whichever trigger the fragment
    /// belongs to fills the list; they cannot both match, since one scans back to a
    /// colon and the other to an at-sign.
    private func refreshSuggestions() {
        if let completed = EmojiShortcodeTrigger.completed(in: text) {
            text.replaceSubrange(completed.range, with: completed.emoji)
            suggestions = []
            return
        }

        if let pending = MentionTrigger.pending(in: text) {
            suggestions = mentionMatches(for: pending.query).map(CompletionSuggestion.mention)
            // The query changed, so any previous highlight refers to a row that is gone.
            selectedSuggestion = 0
            return
        }

        guard let pending = EmojiShortcodeTrigger.pending(in: text) else {
            suggestions = []
            return
        }
        suggestions = EmojiShortcodeIndex.matches(for: pending.query).map(CompletionSuggestion.emoji)
        selectedSuggestion = 0
    }

    /// People matching what has been typed after the `@`.
    ///
    /// A name that is already a mention in this draft offers nothing: completing one
    /// leaves the full name sitting at the caret, which the trigger would read as a
    /// fragment and immediately offer the same person again.
    private func mentionMatches(for query: String) -> [MentionCandidate] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !resolvedMentions.contains(where: { $0.displayName == typed }) else { return [] }
        return MentionDirectory.matches(for: typed, in: mentionCandidates)
    }

    /// Accepts the highlighted suggestion. Reports whether there was one to accept, so
    /// callers can fall through to whatever the key normally does.
    private func completeSelection() -> Bool {
        guard suggestions.indices.contains(selectedSuggestion) else { return false }
        switch suggestions[selectedSuggestion] {
        case .emoji(let match): return complete(withEmoji: match)
        case .mention(let candidate): return complete(withMention: candidate)
        }
    }

    @discardableResult
    private func complete(withEmoji match: EmojiShortcode) -> Bool {
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

    /// Writes a person's name into the draft and remembers who it stands for.
    @discardableResult
    private func complete(withMention candidate: MentionCandidate) -> Bool {
        guard let pending = MentionTrigger.pending(in: text) else {
            suggestions = []
            return false
        }
        text.replaceSubrange(pending.range, with: "@\(candidate.displayName) ")
        if !resolvedMentions.contains(candidate) { resolvedMentions.append(candidate) }
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

/// Stages the clipboard's images when ⌘V arrives, and otherwise stays out of the way.
///
/// Watches keys ahead of `NSApplication.sendEvent(_:)` rather than taking the paste
/// command through `onPasteCommand(of:)`: while the field has focus that command is
/// answered by its field editor, which reaches for text and drops everything else, so a
/// handler further out never hears it. A local monitor is the one hook that runs earlier.
/// The event is passed along untouched whenever nothing was staged, which leaves pasting
/// text — and every other ⌘V in the app — exactly as it was.
private struct ImagePasteHandler: ViewModifier {
    /// Only the focused composer answers, so the two a thread can have on screen at once
    /// never both stage the same image.
    let isEnabled: Bool
    let onPaste: ([PendingAttachment]) -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: install)
            .onDisappear(perform: remove)
            .onChange(of: isEnabled) { install() }
    }

    /// Idempotent, so appearing and losing focus can both call it without keeping two
    /// monitors — or none, after a composer that was hidden comes back.
    private func install() {
        remove()
        guard isEnabled else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isPaste(event) else { return event }
            let images = PasteboardImages.attachments(on: .general)
            guard !images.isEmpty else { return event }
            onPaste(images)
            // Swallowed, so the text flavour of the same copy is not also pasted behind
            // the attachment.
            return nil
        }
    }

    private func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// ⌘V and nothing else — ⇧⌘V is Paste and Match Style, which is about text.
    private func isPaste(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
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
    MessageComposer(placeholder: "Message Engineering", isSending: false) { _ in }
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
    ) { _ in }
    .frame(width: 600)
}

#Preview("Mentioning") {
    MessageComposer(
        placeholder: "Message Engineering",
        isSending: false,
        mentionCandidates: [
            MentionCandidate(userName: "users/1", displayName: "Ada Lovelace", photoURL: nil),
            MentionCandidate(userName: "users/2", displayName: "Grace Hopper", photoURL: nil),
            .everyone,
        ]
    ) { _ in }
    .frame(width: 600)
}
