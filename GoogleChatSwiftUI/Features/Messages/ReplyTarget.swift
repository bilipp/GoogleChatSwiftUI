import Foundation

/// The message an inline reply is aimed at, while it is being composed.
///
/// Carries the thread the reply has to be posted into rather than leaving that to the
/// composer, because Chat refuses a quote that crosses threads. In the main transcript
/// that rule falls out of what is being quoted: answering a reply means answering
/// inside its thread, and answering a message that starts one means starting another.
/// A reply composed inside a thread pane names that thread outright.
struct ReplyTarget: Equatable, Sendable {
    /// Resource name of the quoted message, e.g. `spaces/AAAA/messages/BBBB`.
    let messageName: String
    /// Thread to post the reply into, or nil for the main conversation.
    let threadName: String?
    /// Who wrote the quoted message, for the "Replying to …" line.
    let authorName: String
    /// One-line rendering of the quoted message.
    let preview: String

    init(messageName: String, threadName: String?, authorName: String, preview: String) {
        self.messageName = messageName
        self.threadName = threadName
        self.authorName = authorName
        self.preview = preview
    }

    /// - Parameter threadName: the thread to post into, for a reply composed inside a
    ///   thread pane. Left out in the main transcript, where the quoted message's own
    ///   position decides.
    init(message: CachedMessage, authorName: String, in threadName: String? = nil) {
        self.init(
            messageName: message.name,
            threadName: threadName ?? (message.isThreadReply ? message.threadName : nil),
            authorName: authorName,
            preview: QuotedMessagePreview.line(of: message)
        )
    }
}

/// What a reply shows of the message it answers.
///
/// Resolved against the cache first and the server's snapshot second, so a quote of a
/// message that has since been edited or deleted reads as it stands now — and a quote
/// of something older than the backfilled history still says what it said.
struct QuotedMessagePreview: Equatable {
    /// Resource name of the quoted message, for jumping to it.
    let messageName: String
    let authorName: String
    let text: String

    /// Flattened to one line: a quote is a pointer to a message, not a second copy of
    /// it, and the transcript reads worse when a reply is taller than the thing it
    /// answers. Markup is stripped for the same reason it is in notifications — the
    /// asterisks would be all that survived the truncation.
    static func line(of message: CachedMessage) -> String {
        let plain = ChatTextRenderer.plainText(message.summaryText)
        return plain
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Resolves what a reply quotes, given the rows a view already has to hand.
///
/// A separate type because both the transcript and the thread pane need the same
/// answer from the same two dictionaries they each already build.
struct QuotedMessageResolver {
    let messagesByName: [String: CachedMessage]
    let usersByID: [String: CachedUser]

    /// - Returns: nil when `message` is not a reply at all.
    func preview(for message: CachedMessage) -> QuotedMessagePreview? {
        guard let quotedName = message.quotedMessageName else { return nil }

        if let original = messagesByName[quotedName] {
            return QuotedMessagePreview(
                messageName: quotedName,
                authorName: authorName(of: original),
                text: QuotedMessagePreview.line(of: original)
            )
        }

        // Not in the cache: the snapshot the server sent with the reply is all there is.
        return QuotedMessagePreview(
            messageName: quotedName,
            authorName: displayName(for: message.quotedMessageSender)
                ?? SenderIdentity.unnamedPerson,
            text: message.quotedMessageText.map(ChatTextRenderer.plainText) ?? "Quoted message"
        )
    }

    /// Who wrote a message, by the same rules the bubble names its sender by — including
    /// an app posting, which is named "App" rather than "Unknown".
    func authorName(of message: CachedMessage) -> String {
        SenderIdentity(
            message: message,
            sender: message.senderName.flatMap { usersByID[$0] }
        ).name
    }

    /// The snapshot's author field is documented only as an "author name", without
    /// saying which kind, so a resource name is resolved through the directory and
    /// anything else is taken as already human-readable.
    private func displayName(for sender: String?) -> String? {
        guard let sender, !sender.isEmpty else { return nil }
        guard sender.hasPrefix("users/") else { return sender }
        return usersByID[sender]?.displayName
    }
}
