import SwiftUI

/// Highlighted code, remembered.
///
/// Detecting and lexing one fourteen-line Swift snippet measures at about 1.9 ms — 1.2 ms
/// of that in detection, which is seventy substring searches over the block. That is
/// nothing once, and far too much per frame: a message's blocks are rebuilt on every
/// body evaluation, and a transcript being scrolled evaluates constantly. So the result
/// is cached, keyed by the text, the language and the theme it was coloured for.
///
/// The eviction is deliberately blunt — past the cap the whole table goes, rather than
/// tracking which entry was used least. A transcript reads in one direction, so the
/// entries worth keeping are the recent ones either way, and a flush costs one lex of
/// whatever is still on screen.
@MainActor enum HighlightedCode {
    private struct Key: Hashable {
        let code: String
        let language: CodeLanguage?
        let isDark: Bool
    }

    private static var entries: [Key: AttributedString] = [:]
    private static let capacity = 240

    /// Styled code for a block.
    ///
    /// - Parameter language: the tag from the fence, when there was one. Nil asks for
    ///   detection, whose answer is cached with everything else.
    static func attributed(_ code: String, language: CodeLanguage?, isDark: Bool) -> AttributedString {
        let key = Key(code: code, language: language, isDark: isDark)
        if let cached = entries[key] { return cached }

        let resolved = language ?? CodeLanguage.detect(code)
        let styled = CodeSyntax.attributed(
            code,
            language: resolved,
            palette: isDark ? .dark : .light
        )
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = styled
        return styled
    }
}
