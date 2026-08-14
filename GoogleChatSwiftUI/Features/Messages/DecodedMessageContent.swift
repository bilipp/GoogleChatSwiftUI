import Foundation

/// Cards and smart chips, decoded once per distinct payload.
///
/// ``CachedMessage`` stores both as raw JSON — a card is a deeply nested tree of a dozen
/// widget types, which would be an enormous schema for something only ever read and
/// re-rendered — and decodes on demand. The comment on those properties used to argue the
/// decode was free because "SwiftUI re-evaluates only when the underlying row changes",
/// and that is not what SwiftUI does: a body re-runs when *anything* it observes changes,
/// so a card message re-decoded its JSON on every unrelated update to the transcript
/// around it, and again for every row the lazy stack built while scrolling.
///
/// Keyed on the payload itself rather than on the message, which is what makes the entry
/// invalidate itself: an edited card arrives as different bytes and therefore misses,
/// while the same card asked for on the next frame hits. Hashing a few kilobytes is
/// nowhere near the cost of decoding them.
///
/// A view-layer memo, deliberately: the model keeps the decode, since that is what a card
/// message *is*, and this only remembers the answer.
@MainActor enum DecodedMessageContent {
    private static var cardEntries: [Data: [ChatCard]] = [:]
    private static var linkEntries: [Data: [RichLinkMetadata]] = [:]
    /// Blunt eviction, as in ``RenderedChatText`` and ``HighlightedCode``: a transcript
    /// reads in one direction, so past the cap the whole table goes and the entries worth
    /// keeping are re-decoded from what is still on screen.
    private static let capacity = 200

    static func cards(of message: CachedMessage) -> [ChatCard] {
        guard let payload = message.cardsJSON, !message.isDeleted else { return [] }
        if let cached = cardEntries[payload] { return cached }

        let decoded = message.cards
        if cardEntries.count >= capacity { cardEntries.removeAll(keepingCapacity: true) }
        cardEntries[payload] = decoded
        return decoded
    }

    static func richLinks(of message: CachedMessage) -> [RichLinkMetadata] {
        guard let payload = message.richLinksJSON, !message.isDeleted else { return [] }
        if let cached = linkEntries[payload] { return cached }

        let decoded = message.richLinks
        if linkEntries.count >= capacity { linkEntries.removeAll(keepingCapacity: true) }
        linkEntries[payload] = decoded
        return decoded
    }

    /// Attachments that came with a forwarded message, and the mentions and rich links
    /// Chat parsed out of its body.
    ///
    /// Both memoised for the reason the two above are: they are read while building a
    /// bubble's body, which re-runs on every unrelated change to the transcript around it.
    /// Forwards are rare, so these tables stay nearly empty in most conversations — but a
    /// space where people forward a lot would otherwise re-decode on every frame.
    static func forwardedAttachments(of message: CachedMessage) -> [ChatAttachment] {
        guard let payload = message.quotedAttachmentsJSON, !message.isDeleted else { return [] }
        if let cached = forwardedAttachmentEntries[payload] { return cached }

        let decoded = message.quotedAttachments
        if forwardedAttachmentEntries.count >= capacity {
            forwardedAttachmentEntries.removeAll(keepingCapacity: true)
        }
        forwardedAttachmentEntries[payload] = decoded
        return decoded
    }

    static func forwardedAnnotations(of message: CachedMessage) -> [ChatAnnotation] {
        guard let payload = message.quotedAnnotationsJSON, !message.isDeleted else { return [] }
        if let cached = forwardedAnnotationEntries[payload] { return cached }

        let decoded = message.quotedAnnotations
        if forwardedAnnotationEntries.count >= capacity {
            forwardedAnnotationEntries.removeAll(keepingCapacity: true)
        }
        forwardedAnnotationEntries[payload] = decoded
        return decoded
    }

    private static var forwardedAttachmentEntries: [Data: [ChatAttachment]] = [:]
    private static var forwardedAnnotationEntries: [Data: [ChatAnnotation]] = [:]

    /// Drive links that Chat did not annotate, found in the message text.
    ///
    /// Chat annotates most Drive URLs, but not all: a link pasted into a space where the
    /// sender's client did not resolve it arrives as plain text, and it deserves the same
    /// preview as one that came through as a rich link. Annotated files are excluded here
    /// rather than at the call site so a link is never previewed twice.
    ///
    /// Memoised for the reason the decodes above are — this runs `NSDataDetector` over
    /// the body, and a body re-runs on every unrelated change to the transcript around
    /// it. Keyed on the text so an edit that adds a link is picked up and an unchanged
    /// message is scanned once.
    static func bareDriveLinks(of message: CachedMessage) -> [DriveFileLink] {
        guard !message.isDeleted, let text = message.text, !text.isEmpty else { return [] }
        if let cached = driveEntries[text] { return cached }

        let annotated = Set(richLinks(of: message).compactMap(DriveFileLinkParser.fileID(of:)))
        let found = DriveFileLinkParser.links(in: text).filter { !annotated.contains($0.fileID) }

        if driveEntries.count >= capacity { driveEntries.removeAll(keepingCapacity: true) }
        driveEntries[text] = found
        return found
    }

    private static var driveEntries: [String: [DriveFileLink]] = [:]
}
