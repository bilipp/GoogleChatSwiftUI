import SwiftUI

/// Parsed message text, remembered.
///
/// ``ChatTextRenderer`` is not cheap: one message goes through a recursive inline pass
/// over its characters, an `NSDataDetector` sweep for links, and a search per mentioned
/// name. That is nothing once and far too much per frame — a bubble's blocks are built
/// in its `body`, and a body re-runs whenever anything it observes changes, which in a
/// transcript means every arriving message, every directory lookup that lands, and every
/// row the lazy stack builds while scrolling. So the result is kept.
///
/// The same reasoning, and the same blunt eviction, as ``HighlightedCode`` — which
/// caches the *colouring* of a fenced block, where this caches the parse that found the
/// block in the first place. Past the cap the whole table goes rather than tracking which
/// entry was used least: a transcript reads in one direction, so the entries worth
/// keeping are the recent ones either way, and a flush costs one parse of whatever is
/// still on screen.
///
/// Nothing here keys on the colour scheme, unlike the code cache. The renderer's colours
/// are SwiftUI's own dynamic ones — `.accentColor`, `.primary` — which resolve when the
/// text is drawn rather than when it is parsed, so one entry is correct in both
/// appearances. `isOwn` *is* part of the key, because that switches between two different
/// colours rather than two renderings of one.
///
/// ``ChatTextRenderer`` itself stays uncached and `nonisolated`: the notification banner
/// is assembled inside an actor, and the tests call it directly.
@MainActor enum RenderedChatText {
    private struct BlocksKey: Hashable {
        let body: ChatMessageBody
        let mentions: [String: String]
        let isOwn: Bool
    }

    private static var blockEntries: [BlocksKey: [ChatBlock]] = [:]
    private static var plainEntries: [String: String] = [:]
    private static let capacity = 500

    /// The blocks of a message, parsed once per distinct body.
    ///
    /// The mentions are part of the key as well as the text: a body that names somebody
    /// renders differently once the directory answers for them, and an entry made
    /// before that must not outlive it.
    static func blocks(
        _ body: ChatMessageBody,
        mentions: [String: String] = [:],
        isOwn: Bool = false
    ) -> [ChatBlock] {
        let key = BlocksKey(body: body, mentions: mentions, isOwn: isOwn)
        if let cached = blockEntries[key] { return cached }

        let parsed = ChatTextRenderer.blocks(
            body.text,
            mentions: mentions,
            source: body.source,
            isOwn: isOwn
        )
        if blockEntries.count >= capacity { blockEntries.removeAll(keepingCapacity: true) }
        blockEntries[key] = parsed
        return parsed
    }

    /// Markup stripped away, for accessibility labels and one-line quote previews.
    ///
    /// Kept in its own table rather than derived from ``blocks(_:mentionNames:isOwn:)``:
    /// this is asked for with no mentions and no side, so sharing the block table would
    /// mean a second entry for every message that also renders — the same text stored
    /// twice to save a join of a few strings.
    static func plainText(_ raw: String) -> String {
        if let cached = plainEntries[raw] { return cached }

        let stripped = ChatTextRenderer.plainText(raw)
        if plainEntries.count >= capacity { plainEntries.removeAll(keepingCapacity: true) }
        plainEntries[raw] = stripped
        return stripped
    }
}
