import Foundation
import SwiftUI

/// Marks runs that came from `` `code` ``.
///
/// Link detection and mention highlighting consult this: a URL inside a code span
/// is sample text rather than somewhere to navigate, and `@name` in a code span is
/// a variable, not a person.
nonisolated enum ChatCodeAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "chatCode"
}

/// One piece of a formatted message.
///
/// Chat's block formats — quotes, bullets, fenced code — cannot be expressed as
/// attributes on a single string, because SwiftUI's `Text` ignores the paragraph
/// styles that would carry them. They are modelled as separate blocks and laid out
/// by ``FormattedMessageText`` instead.
nonisolated enum ChatBlock: Sendable {
    case paragraph(AttributedString)
    /// Consecutive `- item` / `* item` lines.
    case bulletList([AttributedString])
    /// Consecutive `> quoted` lines, one entry per line.
    case quote([AttributedString])
    /// The body of a ```` ``` ```` fence, verbatim — no inline markup applies inside.
    case codeBlock(String)
}

/// Turns Chat's plain-text-with-markup into styled text.
///
/// Chat sends its formatting literally in `text` — `*bold*`, `_italic_`,
/// `~strike~`, `` `code` ``, ```` ```blocks``` ````, `> quotes` and `- bullets` —
/// so rendering it raw shows the markup characters. Mentions arrive as separate
/// annotations rather than inline markup.
///
/// Syntax follows <https://support.google.com/chat/answer/7649118>.
nonisolated enum ChatTextRenderer {
    // MARK: - Entry points

    /// Parses `raw` into the blocks that make up a message.
    ///
    /// - Parameter mentionNames: display names of users mentioned in this message,
    ///   used to highlight the matching `@Name` spans.
    static func blocks(
        _ raw: String,
        mentionNames: [String] = [],
        isOwn: Bool = false
    ) -> [ChatBlock] {
        var result: [ChatBlock] = []
        for segment in fencedSegments(in: raw) {
            switch segment {
            case .code(let body):
                result.append(.codeBlock(body))
            case .text(let body):
                result.append(
                    contentsOf: lineBlocks(body, mentionNames: mentionNames, isOwn: isOwn)
                )
            }
        }
        // Markup that resolves to nothing at all — an empty fence, whitespace — would
        // otherwise collapse the bubble to bare padding. Show what was sent instead.
        if result.isEmpty, !raw.isEmpty { return [.paragraph(AttributedString(raw))] }
        return result
    }

    /// A single styled string, for the places that render one `Text` and have no
    /// room for block layout.
    ///
    /// Block formats collapse: bullets keep their marker, quotes and code blocks
    /// keep their text but lose their decoration.
    static func attributed(
        _ raw: String,
        mentionNames: [String] = [],
        isOwn: Bool = false
    ) -> AttributedString {
        var result = AttributedString()
        for block in blocks(raw, mentionNames: mentionNames, isOwn: isOwn) {
            if !result.characters.isEmpty { result.append(AttributedString("\n")) }
            switch block {
            case .paragraph(let text):
                result.append(text)
            case .bulletList(let items):
                for (offset, item) in items.enumerated() {
                    if offset > 0 { result.append(AttributedString("\n")) }
                    result.append(AttributedString("• "))
                    result.append(item)
                }
            case .quote(let lines):
                for (offset, line) in lines.enumerated() {
                    if offset > 0 { result.append(AttributedString("\n")) }
                    result.append(line)
                }
            case .codeBlock(let body):
                result.append(codeRun(body, isOwn: isOwn))
            }
        }
        return result
    }

    /// Markup stripped away entirely, for notification banners, the menu bar and
    /// accessibility labels — anywhere the styling cannot be shown and the raw
    /// asterisks would just be noise.
    static func plainText(_ raw: String) -> String {
        String(attributed(raw).characters)
    }

    // MARK: - Fenced code blocks

    private enum Segment {
        case text(String)
        case code(String)
    }

    /// Splits the message at ```` ``` ```` fences.
    ///
    /// Fences are matched anywhere rather than only at the start of a line, because
    /// Chat accepts ```` ```code``` ```` inline in a sentence as well as spanning
    /// lines. An unmatched opening fence is literal text.
    private static func fencedSegments(in raw: String) -> [Segment] {
        let fence = "```"
        var segments: [Segment] = []
        var rest = Substring(raw)

        while let open = rest.range(of: fence) {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: fence) else { break }

            let before = String(rest[..<open.lowerBound])
            if !before.isEmpty { segments.append(.text(before)) }

            let body = fenceBody(String(afterOpen[..<close.lowerBound]))
            // An empty fence carries nothing to show; dropping it beats an empty box.
            if !body.isEmpty { segments.append(.code(body)) }

            rest = afterOpen[close.upperBound...]
        }

        if !rest.isEmpty { segments.append(.text(String(rest))) }
        return segments
    }

    /// Drops the newline people type straight after the opening fence, and any
    /// trailing blank space before the closing one, so the rendered box has no
    /// empty first or last line. Interior blank lines are the author's.
    private static func fenceBody(_ source: String) -> String {
        var body = source
        if body.hasPrefix("\r\n") {
            body.removeFirst(2)
        } else if body.hasPrefix("\n") {
            body.removeFirst()
        }
        while let last = body.last, last.isWhitespace { body.removeLast() }
        return body
    }

    // MARK: - Line blocks

    /// Groups the lines of a fence-free stretch of text into quotes, bullet lists
    /// and paragraphs. Runs of the same kind merge into one block, which is what
    /// makes a multi-line quote read as a single quotation.
    private static func lineBlocks(
        _ text: String,
        mentionNames: [String],
        isOwn: Bool
    ) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var quotes: [String] = []

        func inline(_ line: String) -> AttributedString {
            inlineText(line, mentionNames: mentionNames, isOwn: isOwn)
        }

        func flushParagraph() {
            // Blank lines at either end are the gap left by an adjacent block, not
            // spacing the author asked for. Interior ones are kept as written.
            while paragraph.first?.allSatisfy(\.isWhitespace) == true { paragraph.removeFirst() }
            while paragraph.last?.allSatisfy(\.isWhitespace) == true { paragraph.removeLast() }
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }

        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bulletList(bullets.map(inline)))
            bullets = []
        }

        func flushQuotes() {
            guard !quotes.isEmpty else { return }
            blocks.append(.quote(quotes.map(inline)))
            quotes = []
        }

        for line in text.components(separatedBy: "\n") {
            if let quoted = quoteBody(of: line) {
                flushParagraph()
                flushBullets()
                quotes.append(quoted)
            } else if let bullet = bulletBody(of: line) {
                flushParagraph()
                flushQuotes()
                bullets.append(bullet)
            } else {
                flushBullets()
                flushQuotes()
                paragraph.append(line)
            }
        }

        flushParagraph()
        flushBullets()
        flushQuotes()
        return blocks
    }

    /// The text after a leading `>`, or nil if this is not a quote line.
    private static func quoteBody(of line: String) -> String? {
        var rest = line.drop { $0 == " " || $0 == "\t" }
        guard rest.first == ">" else { return nil }
        rest = rest.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// The text after a leading `-` or `*` bullet marker, or nil if this is not a
    /// list item.
    ///
    /// The marker must be followed by whitespace. That is the only thing separating
    /// a `* item` bullet from a line that simply opens with `*bold*`.
    private static func bulletBody(of line: String) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let marker = trimmed.first, marker == "-" || marker == "*" else { return nil }
        let rest = trimmed.dropFirst()
        guard let next = rest.first, next == " " || next == "\t" else { return nil }
        return String(rest.drop { $0 == " " || $0 == "\t" })
    }

    // MARK: - Inline markup

    private struct InlineStyle: OptionSet, Sendable {
        let rawValue: Int
        static let bold = InlineStyle(rawValue: 1 << 0)
        static let italic = InlineStyle(rawValue: 1 << 1)
        static let strikethrough = InlineStyle(rawValue: 1 << 2)
    }

    private enum Delimiter: Sendable {
        case bold, italic, strikethrough, code

        init?(_ character: Character) {
            switch character {
            case "*": self = .bold
            case "_": self = .italic
            case "~": self = .strikethrough
            case "`": self = .code
            default: return nil
            }
        }

        var character: Character {
            switch self {
            case .bold: "*"
            case .italic: "_"
            case .strikethrough: "~"
            case .code: "`"
            }
        }

        /// Nil for code, whose contents are never parsed further and so carry no
        /// nestable style.
        var style: InlineStyle? {
            switch self {
            case .bold: .bold
            case .italic: .italic
            case .strikethrough: .strikethrough
            case .code: nil
            }
        }
    }

    private static func inlineText(
        _ source: String,
        mentionNames: [String],
        isOwn: Bool
    ) -> AttributedString {
        var text = parseInline(Array(source), style: [], isOwn: isOwn)
        linkifyURLs(in: &text, isOwn: isOwn)
        highlightMentions(in: &text, names: mentionNames, isOwn: isOwn)
        return text
    }

    /// Recursive-descent over one line's characters.
    ///
    /// Recursion is what lets styles nest — `*_both_*` — which the previous
    /// delimiter-at-a-time pass could not express. A delimiter that finds no valid
    /// partner stays literal, so a lone `*` or a `snake_case` identifier is left
    /// exactly as typed instead of swallowing the rest of the message.
    private static func parseInline(
        _ characters: [Character],
        style: InlineStyle,
        isOwn: Bool
    ) -> AttributedString {
        var result = AttributedString()
        var literal = ""
        var index = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            result.append(styledRun(literal, style: style))
            literal = ""
        }

        while index < characters.count {
            guard let delimiter = Delimiter(characters[index]),
                  // Re-opening a style already in effect would leave the closing
                  // delimiter with nothing to pair against.
                  delimiter.style.map({ !style.contains($0) }) ?? true,
                  isOpening(characters, at: index),
                  let close = closingIndex(characters, after: index, delimiter: delimiter)
            else {
                literal.append(characters[index])
                index += 1
                continue
            }

            flushLiteral()
            let inner = Array(characters[(index + 1)..<close])
            if let nested = delimiter.style {
                result.append(parseInline(inner, style: style.union(nested), isOwn: isOwn))
            } else {
                result.append(codeRun(String(inner), isOwn: isOwn))
            }
            index = close + 1
        }

        flushLiteral()
        return result
    }

    /// A delimiter opens a span only at a word boundary and with something other
    /// than space after it. Without that rule `snake_case` renders as italic and
    /// the `_` in a URL path eats half the link.
    private static func isOpening(_ characters: [Character], at index: Int) -> Bool {
        if index > 0 {
            let previous = characters[index - 1]
            if previous.isLetter || previous.isNumber { return false }
        }
        guard index + 1 < characters.count else { return false }
        let next = characters[index + 1]
        return !next.isWhitespace && next != characters[index]
    }

    /// The mirror rule: a closing delimiter hugs the text it ends and is not
    /// followed by more word characters.
    private static func isClosing(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = characters[index - 1]
        if previous.isWhitespace || previous == characters[index] { return false }
        guard index + 1 < characters.count else { return true }
        let next = characters[index + 1]
        return !(next.isLetter || next.isNumber)
    }

    /// Finds the delimiter that closes the span opened at `open`.
    ///
    /// Code spans are stepped over wholesale, so the `*` in `` *see `a*b` here* ``
    /// belongs to the code rather than closing the bold early.
    private static func closingIndex(
        _ characters: [Character],
        after open: Int,
        delimiter: Delimiter
    ) -> Int? {
        var index = open + 1
        while index < characters.count {
            if delimiter != .code,
               characters[index] == "`",
               isOpening(characters, at: index),
               let codeClose = literalClosingIndex(characters, after: index, character: "`") {
                index = codeClose + 1
                continue
            }
            if characters[index] == delimiter.character, isClosing(characters, at: index) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func literalClosingIndex(
        _ characters: [Character],
        after open: Int,
        character: Character
    ) -> Int? {
        var index = open + 1
        while index < characters.count {
            if characters[index] == character, isClosing(characters, at: index) { return index }
            index += 1
        }
        return nil
    }

    // MARK: - Runs

    /// Left unstyled when no markup applies, so the surrounding view's font wins
    /// and plain messages look exactly as they did before.
    private static func styledRun(_ literal: String, style: InlineStyle) -> AttributedString {
        var run = AttributedString(literal)
        if !style.isDisjoint(with: [.bold, .italic]) {
            var font = Font.body
            if style.contains(.bold) { font = font.bold() }
            if style.contains(.italic) { font = font.italic() }
            run.font = font
        }
        if style.contains(.strikethrough) { run.strikethroughStyle = .single }
        return run
    }

    static func codeRun(_ body: String, isOwn: Bool) -> AttributedString {
        var run = AttributedString(body)
        run.font = .system(.body, design: .monospaced)
        // A tint of the text colour, so the wash reads on both the accent-filled
        // own bubble and the neutral one.
        run.backgroundColor = isOwn ? .white.opacity(0.18) : .primary.opacity(0.07)
        run[ChatCodeAttribute.self] = true
        return run
    }

    // MARK: - Links

    /// Detector is built once: `NSDataDetector` compiles a regex on init, and doing
    /// that per message would show up while scrolling a long transcript.
    private static let urlDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Makes bare URLs tappable.
    ///
    /// Chat sends links as plain text with no markup around them, so nothing else in
    /// this renderer would notice them. `NSDataDetector` is used rather than a regex
    /// because it handles the awkward cases — trailing punctuation, parenthesised
    /// URLs, bare domains without a scheme — that hand-rolled patterns get wrong.
    private static func linkifyURLs(in text: inout AttributedString, isOwn: Bool) {
        let plain = String(text.characters)
        guard let urlDetector, !plain.isEmpty else { return }

        let matches = urlDetector.matches(
            in: plain,
            range: NSRange(plain.startIndex..., in: plain)
        )

        // Applied back to front so each replacement leaves earlier indices valid.
        for match in matches.reversed() {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: plain),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: text),
                  let upper = AttributedString.Index(stringRange.upperBound, within: text),
                  !isCode(text[lower..<upper])
            else { continue }

            text[lower..<upper].link = url
            text[lower..<upper].underlineStyle = .single
            // Accent-on-accent would vanish inside an own-message bubble.
            text[lower..<upper].foregroundColor = isOwn ? .white : .accentColor
        }
    }

    // MARK: - Mentions

    /// Highlights `@Name` for each mentioned user.
    ///
    /// Matched by name rather than by the annotation's `startIndex`: those offsets
    /// are relative to the raw text, which markup stripping has already shifted, and
    /// the docs do not state whether they count code points or UTF-16 units.
    private static func highlightMentions(
        in text: inout AttributedString,
        names: [String],
        isOwn: Bool
    ) {
        for name in names {
            for candidate in ["@\(name)", name] {
                guard !candidate.isEmpty,
                      let range = text.range(of: candidate),
                      !isCode(text[range])
                else { continue }
                text[range].font = (text[range].font ?? .body).weight(.semibold)
                // Accent-on-accent would be invisible inside an own-message bubble.
                text[range].foregroundColor = isOwn ? .white : .accentColor
                break
            }
        }
    }

    private static func isCode(_ slice: AttributedSubstring) -> Bool {
        slice.runs.contains { $0[ChatCodeAttribute.self] == true }
    }
}
