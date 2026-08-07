import Foundation

/// Finds the `:shortcode` fragment a composer's text ends in.
///
/// Only the trailing fragment is considered. `TextField` does not publish its caret
/// position, so the end of the string is the one place the caret is known to be — and
/// it is where it sits for the case this exists to serve, typing a shortcode as part
/// of writing a message. Editing a shortcode back in the middle of a finished sentence
/// gets no suggestions. ``MentionTrigger`` accepts the same limit for the same reason;
/// should the composer ever move to an `NSTextView`, both become a caret offset and
/// nothing else about either type changes.
nonisolated enum EmojiShortcodeTrigger {
    /// A fragment being typed, and where it sits in the text.
    struct Match: Equatable {
        /// The text after the colon, e.g. `smile` for `:smile`.
        let query: String
        /// The span to replace, colon included.
        let range: Range<String.Index>
    }

    /// The in-progress `:fragment` at the end of `text`, if there is one.
    static func pending(in text: String) -> Match? {
        guard let span = trailingShortcode(in: text),
              span.query.count >= EmojiShortcodeIndex.minimumQueryLength
        else { return nil }
        return span
    }

    /// A finished `:shortcode:` at the end of `text`, resolved to its emoji.
    ///
    /// Typing the closing colon is an unambiguous statement of which emoji was meant,
    /// so it substitutes without going through the list — the same as Chat itself.
    static func completed(in text: String) -> (emoji: String, range: Range<String.Index>)? {
        guard text.last == ":" else { return nil }
        let withoutClosing = String(text.dropLast())
        guard let span = trailingShortcode(in: withoutClosing),
              !span.query.isEmpty,
              let emoji = EmojiShortcodeIndex.emoji(forShortcode: span.query)
        else { return nil }
        // Extended back over the closing colon that was dropped for the scan.
        return (emoji, span.range.lowerBound..<text.endIndex)
    }

    /// Scans back from the end over shortcode characters to an opening colon.
    private static func trailingShortcode(in text: String) -> Match? {
        var start = text.endIndex
        var length = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard isShortcodeCharacter(text[previous]) else { break }
            guard length < EmojiShortcodeIndex.maximumQueryLength else { return nil }
            start = previous
            length += 1
        }

        guard start > text.startIndex else { return nil }
        let colon = text.index(before: start)
        guard text[colon] == ":" else { return nil }

        // A colon that follows a word is punctuation or a time — `12:30`, `note:foo` —
        // not the start of a shortcode.
        if colon > text.startIndex {
            let preceding = text[text.index(before: colon)]
            guard preceding.isWhitespace || preceding.isNewline else { return nil }
        }

        return Match(query: String(text[start..<text.endIndex]), range: colon..<text.endIndex)
    }

    private static func isShortcodeCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(EmojiShortcodeIndex.shortcodeCharacters.contains)
    }
}
