import Foundation

/// Finds the `@fragment` a composer's text ends in.
///
/// The sibling of ``EmojiShortcodeTrigger``, and trailing-only for the same reason: the
/// composer's editor publishes no caret position, so the end of the string is the one
/// place the caret is known to be. Editing a name back in the middle of a finished sentence
/// gets no suggestions.
///
/// The one real difference is spaces. A shortcode is a single word; a display name is
/// "Ada Lovelace", so the fragment has to survive the space between the two halves of
/// a name being typed — which is also why it needs bounds that a shortcode does not.
/// Past a few words this is prose that happens to follow an at-sign.
nonisolated enum MentionTrigger {
    /// A fragment being typed, and where it sits in the text.
    struct Match: Equatable {
        /// The text after the `@`, e.g. `Ada L` for `@Ada L`. May end in a space
        /// while the second half of a name is still to come.
        let query: String
        /// The span to replace, `@` included.
        let range: Range<String.Index>
    }

    /// Longest fragment worth completing. Nobody's name runs this long, so past it
    /// the `@` opened a sentence rather than a mention.
    static let maximumQueryLength = 64

    /// How many words a name being typed may span. Enough for "Maria del Carmen
    /// Rodríguez", short enough that a stray at-sign does not keep the list open for
    /// the rest of the paragraph.
    static let maximumQueryWords = 4

    /// The in-progress `@fragment` at the end of `text`, if there is one.
    ///
    /// A bare `@` matches with an empty query, which is how Chat itself behaves: the
    /// point of typing one is to be shown who is here.
    static func pending(in text: String) -> Match? {
        var start = text.endIndex
        var length = 0
        var spaces = 0

        while start > text.startIndex {
            let previous = text.index(before: start)
            let character = text[previous]
            guard isNameCharacter(character) else { break }
            if character == " " {
                spaces += 1
                guard spaces < maximumQueryWords else { return nil }
            }
            guard length < maximumQueryLength else { return nil }
            start = previous
            length += 1
        }

        guard start > text.startIndex else { return nil }
        let at = text.index(before: start)
        guard text[at] == "@" else { return nil }

        // An `@` glued to the preceding word is an email address or a handle already
        // written out, not the start of a name being typed.
        if at > text.startIndex {
            let preceding = text[text.index(before: at)]
            guard preceding.isWhitespace || preceding.isNewline else { return nil }
        }

        let query = String(text[start..<text.endIndex])
        // `@ ` is someone writing an at-sign; everything after it is prose.
        guard query.first != " " else { return nil }
        return Match(query: query, range: at..<text.endIndex)
    }

    /// What a display name may be made of, as far as the scan is concerned.
    ///
    /// Deliberately wider than ASCII letters: the directory holds names with umlauts,
    /// accents, and non-Latin scripts, and a scan that stopped at the first of them
    /// would offer completion to some colleagues and not others.
    static func isNameCharacter(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return character == " " || character == "-" || character == "'" || character == "."
    }
}
