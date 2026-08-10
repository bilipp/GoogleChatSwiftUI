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
}
