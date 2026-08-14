import Foundation

/// A message someone sent on into this conversation from another one.
///
/// The counterpart to ``QuotedMessagePreview``, and deliberately not the same thing. Both
/// come out of Chat's one `quotedMessageMetadata` field, but they answer to different
/// readers. A reply quotes a message that is *here* — one line of context, and a way to go
/// and read the rest. A forward quotes a message that is somewhere else, possibly somewhere
/// this account cannot go at all, so the copy that arrived with it is the only copy there
/// will ever be. Flattening that to one line would throw the message away.
///
/// Which is why this carries a body rather than a string: the forwarded text is rendered by
/// the same passes as any other message, markup and mentions and all.
struct ForwardedMessage: Equatable {
    /// Resource name of the original, in the space it was forwarded out of.
    let messageName: String
    /// The source conversation, e.g. `spaces/AAAA1111`. Nil for a forward Chat described
    /// without one, which leaves nothing to navigate to.
    let sourceSpaceName: String?
    /// What that conversation was called at the time of forwarding — see
    /// ``ForwardedMetadata``. Nil where Chat did not say.
    let sourceTitle: String?
    /// Who wrote the original, or nil where Chat did not say and the directory cannot be
    /// asked — which is not the same as "Unknown", and is shown as nothing rather than as
    /// that word. Chat sends this snapshot field empty often enough in practice that naming
    /// the author "Unknown" would put a wrong-looking line on a great many forwards; the
    /// header above already says where it came from.
    let authorName: String?
    let body: ChatMessageBody
    /// Display names for the people the forwarded body mentions, keyed by resource name.
    let mentions: [String: String]
    let attachments: [AttachmentDisplay]
    let richLinks: [RichLinkMetadata]

    /// Whether there is anything here worth drawing a block around.
    ///
    /// A forward with no text, no files and no chips would be an empty bordered box — which
    /// happens if Chat sends the metadata without a snapshot, and reads better as nothing at
    /// all than as a frame around nothing.
    var isEmpty: Bool {
        body.isEmpty && attachments.isEmpty && richLinks.isEmpty
    }
}

/// What a message carries of another message: Chat's two kinds of quote.
///
/// One type rather than two optional properties on the bubble, because exactly one of them
/// is ever set and a pair of optionals invites the state where both are — a message that is
/// somehow a reply *and* a forward, which Chat has no way to express.
enum QuotedContent: Equatable {
    /// An inline reply, shown as a line of context inside the replying message's bubble.
    case reply(QuotedMessagePreview)
    /// A message forwarded in from elsewhere, shown as a block of its own beneath.
    case forward(ForwardedMessage)

    /// The quote a reply shows, or nil for a forward. For the bubble, which is drawn for a
    /// reply that has no text of its own but not for a forward — see
    /// ``CachedMessage/displayText``.
    var replyPreview: QuotedMessagePreview? {
        guard case .reply(let preview) = self else { return nil }
        return preview
    }

    var forwarded: ForwardedMessage? {
        guard case .forward(let message) = self else { return nil }
        return message
    }
}
