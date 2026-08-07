import Foundation

/// One emoji and the `:shortcode:` that types it.
nonisolated struct EmojiShortcode: Hashable, Identifiable, Sendable {
    let emoji: String
    let shortcode: String

    var id: String { shortcode }

    /// How the shortcode reads in the suggestion list, colons included, because that
    /// is the form the user has to type to reach it again without the list.
    var label: String { ":\(shortcode):" }
}

/// Look-up from a typed `:fragment` to the emoji it should become.
///
/// Names come from ICU via `StringTransform.toUnicodeName` rather than a bundled
/// shortcode database: the transform already knows every assigned code point, so the
/// index tracks Unicode instead of going stale, and there is nothing to hand-maintain.
/// It is stitched onto ``EmojiCatalogue`` so the composer and the reaction picker draw
/// from one set of emoji.
nonisolated enum EmojiShortcodeIndex {
    /// How many suggestions the composer shows at once.
    static let suggestionLimit = 8

    /// Shortest fragment worth completing. One letter after the colon matches so much
    /// of the catalogue that the list is noise, and it would fire on ordinary typing.
    static let minimumQueryLength = 2

    /// Longest fragment worth completing, past which this is prose containing a colon
    /// rather than a shortcode in progress.
    static let maximumQueryLength = 32

    /// Characters allowed inside a shortcode. `+` and `-` are here for `:+1:`/`:-1:`.
    static let shortcodeCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_+-"))

    /// The everyday shortcodes whose Unicode name shares no words with them — nobody
    /// types `:person_with_folded_hands:`. Kept deliberately short: it is a patch over
    /// the naming gap between Unicode and the shortcodes people already know from
    /// Chat and Slack, not a second catalogue.
    private static let aliases: KeyValuePairs<String, String> = [
        "smile": "😄",
        "smiley": "😃",
        "grin": "😁",
        "laughing": "😆",
        "joy": "😂",
        "wink": "😉",
        "blush": "😊",
        "heart_eyes": "😍",
        "thinking": "🤔",
        "cry": "😢",
        "sob": "😭",
        "scream": "😱",
        "rage": "😡",
        "sunglasses": "😎",
        "shrug": "🤷",
        "thumbsup": "👍",
        "+1": "👍",
        "thumbsdown": "👎",
        "-1": "👎",
        "ok_hand": "👌",
        "clap": "👏",
        "wave": "👋",
        "pray": "🙏",
        "muscle": "💪",
        "eyes": "👀",
        "heart": "❤️",
        "broken_heart": "💔",
        "fire": "🔥",
        "tada": "🎉",
        "rocket": "🚀",
        "100": "💯",
        "white_check_mark": "✅",
        "check": "✅",
        "x": "❌",
        "warning": "⚠️",
        "bulb": "💡",
        "star": "⭐",
        "sparkles": "✨",
        "coffee": "☕",
        "beer": "🍺",
        "pizza": "🍕",
        "cake": "🎂",
        "bug": "🐛",
        "ship": "🚢",
    ]

    /// Every completable emoji, built once at first use.
    static let all: [EmojiShortcode] = build()

    private static let byShortcode: [String: String] = Dictionary(
        all.map { ($0.shortcode, $0.emoji) },
        uniquingKeysWith: { first, _ in first }
    )

    /// Suggestions for a fragment typed after a colon, best first.
    ///
    /// The same emoji can be reachable under both an alias and its Unicode name, so
    /// results are collapsed by emoji: a list showing 😄 twice looks broken.
    static func matches(for query: String, limit: Int = suggestionLimit) -> [EmojiShortcode] {
        let needle = query.lowercased()
        guard needle.count >= minimumQueryLength else { return [] }

        let compactNeedle = compact(needle)
        let ranked = all.enumerated().compactMap { index, entry -> (Int, Int, Int, EmojiShortcode)? in
            guard let rank = rank(entry.shortcode, against: needle, compactNeedle) else {
                return nil
            }
            // Shorter names are the more literal reading of the fragment, and the
            // catalogue index keeps the order stable where lengths tie.
            return (rank, entry.shortcode.count, index, entry)
        }
        .sorted { lhs, rhs in
            (lhs.0, lhs.1, lhs.2) < (rhs.0, rhs.1, rhs.2)
        }

        var seen = Set<String>()
        var result: [EmojiShortcode] = []
        for candidate in ranked where seen.insert(candidate.3.emoji).inserted {
            result.append(candidate.3)
            if result.count == limit { break }
        }
        return result
    }

    /// The emoji a fully typed `:shortcode:` stands for, if it names one exactly.
    static func emoji(forShortcode shortcode: String) -> String? {
        byShortcode[shortcode.lowercased()]
    }

    // MARK: - Ranking

    /// Lower is better; `nil` means no match.
    private static func rank(
        _ shortcode: String,
        against needle: String,
        _ compactNeedle: String
    ) -> Int? {
        if shortcode == needle { return 0 }
        if shortcode.hasPrefix(needle) { return 1 }
        // A word start, so `:joy` reaches `face_with_tears_of_joy` — Unicode names read
        // as descriptions, and the memorable word is rarely the first one.
        if shortcode.split(separator: "_").contains(where: { $0.hasPrefix(needle) }) { return 2 }
        if !compactNeedle.isEmpty, compact(shortcode).contains(compactNeedle) { return 3 }
        return nil
    }

    /// Separator-free form, so `:thumbsup` and `:thumbs_up` reach the same entry.
    private static func compact(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Building

    private static func build() -> [EmojiShortcode] {
        var seen = Set<String>()
        var result: [EmojiShortcode] = []

        // Aliases first: where one collides with a derived name, the name people
        // actually type should be the one that wins.
        for (shortcode, emoji) in aliases where seen.insert(shortcode).inserted {
            result.append(EmojiShortcode(emoji: emoji, shortcode: shortcode))
        }

        for category in EmojiCatalogue.categories {
            for emoji in category.emoji {
                guard let shortcode = shortcode(for: emoji),
                      seen.insert(shortcode).inserted
                else { continue }
                result.append(EmojiShortcode(emoji: emoji, shortcode: shortcode))
            }
        }

        return result
    }

    /// `👍` → `thumbs_up_sign`.
    ///
    /// The transform yields `\N{NAME}` per scalar; only the first is of interest, since
    /// the rest are variation selectors and joiners that name no emoji of their own.
    private static func shortcode(for emoji: String) -> String? {
        guard let named = emoji.applyingTransform(.toUnicodeName, reverse: false),
              let open = named.firstIndex(of: "{"),
              let close = named[open...].firstIndex(of: "}")
        else { return nil }

        let name = named[named.index(after: open)..<close].lowercased()
        let words = name.split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: "_")
    }
}
