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

/// Which of Chat's two copies of a body some text came from.
///
/// The API answers for a message twice. `text` is the plain body, and plain means
/// *stripped*: whatever the sender formatted has been taken back out of it, so a
/// message posted with a fenced block arrives as the code with no fence around it and
/// nothing anywhere saying there was one. `formattedText` is the same body with the
/// markup restored, and carries three forms that appear nowhere else — `<users/123>`
/// for a mention, `<url|label>` for a hyperlink, and a backslash before any character
/// that would otherwise read as markup.
///
/// Both go through the same passes. This is what decides whether those three forms are
/// syntax or the literal characters somebody typed.
nonisolated enum ChatTextSource: Sendable, Hashable {
    case plain
    case formatted
}

/// A message body together with the field it came from.
nonisolated struct ChatMessageBody: Sendable, Hashable {
    let text: String
    let source: ChatTextSource

    var isEmpty: Bool { text.isEmpty }
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
    ///
    /// `language` is set only when the opening fence carried a tag we recognise. An
    /// untagged block is nil here and left to ``CodeLanguage/detect(_:)``, which guesses
    /// for the sake of colouring without claiming a name for the block.
    case codeBlock(language: CodeLanguage?, body: String)
}

/// Turns Chat's markup into styled text.
///
/// Chat's formatting is markup in the body itself — `*bold*`, `_italic_`,
/// `~strike~`, `` `code` ``, ```` ```blocks``` ````, `> quotes` and `- bullets` —
/// so rendering it raw shows the markup characters.
///
/// Syntax follows <https://support.google.com/chat/answer/7649118>, plus the three
/// forms only `formattedText` uses — see ``ChatTextSource``.
nonisolated enum ChatTextRenderer {
    // MARK: - Entry points

    /// Parses `raw` into the blocks that make up a message.
    ///
    /// - Parameters:
    ///   - mentions: display names of the people this message mentions, keyed by user
    ///     resource name. `formattedText` names them by resource name and needs the
    ///     map to write anything readable; `text` names them in full already, and the
    ///     names are what the matching `@Name` spans are highlighted by.
    ///   - source: which field `raw` came out of. See ``ChatTextSource``.
    static func blocks(
        _ raw: String,
        mentions: [String: String] = [:],
        source: ChatTextSource = .plain,
        isOwn: Bool = false
    ) -> [ChatBlock] {
        var result: [ChatBlock] = []
        for segment in fencedSegments(in: raw) {
            switch segment {
            case .code(let language, let body):
                result.append(.codeBlock(language: language, body: body))
            case .text(let body):
                result.append(
                    contentsOf: lineBlocks(
                        body,
                        mentions: mentions,
                        source: source,
                        isOwn: isOwn
                    )
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
        mentions: [String: String] = [:],
        source: ChatTextSource = .plain,
        isOwn: Bool = false
    ) -> AttributedString {
        var result = AttributedString()
        for block in blocks(raw, mentions: mentions, source: source, isOwn: isOwn) {
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
            case .codeBlock(_, let body):
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

    // MARK: - Choosing a body

    /// Which of a message's two bodies to render.
    ///
    /// `formattedText` whenever there is one, because it is the only copy that still
    /// says a span was code: Chat resolves formatting as the message is posted and
    /// serves `text` with the markup taken out, so a fenced block reaches `text` as
    /// bare lines and renders as prose however good the parser is.
    ///
    /// The exception is mentions. `formattedText` writes them as `<users/123>`, and a
    /// user the directory has not answered for yet has no name to put there — a raw
    /// resource name on screen is worse than a message that lost its backticks. So a
    /// body naming somebody unknown falls back to the plain copy, where Chat has
    /// already written the name out. The lookup lands within a second or two and the
    /// bubble re-renders with the formatting.
    static func body(
        formatted: String?,
        plain: String?,
        mentions: [String: String]
    ) -> ChatMessageBody {
        let fallback = ChatMessageBody(text: plain ?? "", source: .plain)
        guard let formatted, !formatted.isEmpty else { return fallback }
        guard mentionIDs(in: formatted).allSatisfy({ mentionName(of: $0, in: mentions) != nil })
        else { return fallback }
        return ChatMessageBody(text: formatted, source: .formatted)
    }

    /// The body as the composer would have written it, for the edit field.
    ///
    /// Markup, escapes and `<url|label>` are left exactly as Chat sent them: all three
    /// are valid on the way back in, so fixing a typo posts the same formatting back
    /// rather than flattening the message. Mentions are the exception — `<users/123>`
    /// is not something anyone can edit around — and are written as names, which
    /// `MessageBubble.saveEdit` encodes again on the way out.
    static func editable(_ body: ChatMessageBody, mentions: [String: String]) -> String {
        guard body.source == .formatted else { return body.text }
        var result = body.text
        for id in Set(mentionIDs(in: body.text)) {
            guard let name = mentionName(of: id, in: mentions) else { continue }
            result = result.replacingOccurrences(of: "<\(id)>", with: "@\(name)")
        }
        return result
    }

    /// The user resource names a `formattedText` body mentions.
    static func mentionIDs(in formatted: String) -> [String] {
        var found: [String] = []
        var rest = Substring(formatted)
        while let open = rest.range(of: "<users/") {
            // Past the `<`, so the id is what runs up to the closing bracket.
            let inner = rest[open.lowerBound...].dropFirst()
            guard let close = inner.range(of: ">") else { break }
            found.append(String(inner[..<close.lowerBound]))
            rest = inner[close.upperBound...]
        }
        return found
    }

    /// `users/all` is Chat's own name for everyone in the space. It is never in the
    /// directory, so it is answered here rather than looked up.
    private static func mentionName(of id: String, in mentions: [String: String]) -> String? {
        if let name = mentions[id] { return name }
        return id == MentionCandidate.everyoneName ? MentionCandidate.everyone.displayName : nil
    }

    // MARK: - Fenced code blocks

    private enum Segment {
        case text(String)
        case code(language: CodeLanguage?, body: String)
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

            let fenced = fenceContents(String(afterOpen[..<close.lowerBound]))
            // An empty fence carries nothing to show; dropping it beats an empty box.
            if !fenced.body.isEmpty {
                segments.append(.code(language: fenced.language, body: fenced.body))
            }

            rest = afterOpen[close.upperBound...]
        }

        if !rest.isEmpty { segments.append(.text(String(rest))) }
        return segments
    }

    /// Splits a fence's contents into the language tag on the opening line and the
    /// code beneath it.
    ///
    /// Chat itself has no notion of a tagged fence, but people paste ```` ```swift ````
    /// constantly — out of an editor, a README, another chat client — and without this
    /// the tag renders as a stray first line of code. Which tags count is
    /// ``CodeLanguage/init(tag:)``'s business.
    private static func fenceContents(
        _ source: String
    ) -> (language: CodeLanguage?, body: String) {
        // No newline means a one-line fence like ```make test```, where the first word
        // is code the author wants to see, not a tag.
        guard let newline = source.firstIndex(of: "\n") else { return (nil, fenceBody(source)) }
        let tag = source[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let language = CodeLanguage(tag: tag) else { return (nil, fenceBody(source)) }
        return (language, fenceBody(String(source[source.index(after: newline)...])))
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
        mentions: [String: String],
        source: ChatTextSource,
        isOwn: Bool
    ) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var quotes: [String] = []

        func inline(_ line: String) -> AttributedString {
            inlineText(line, mentions: mentions, source: source, isOwn: isOwn)
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
        _ line: String,
        mentions: [String: String],
        source: ChatTextSource,
        isOwn: Bool
    ) -> AttributedString {
        var text = parseInline(
            Array(line),
            style: [],
            mentions: mentions,
            source: source,
            isOwn: isOwn
        )
        linkifyURLs(in: &text, isOwn: isOwn)
        // Longest first, so `@Ana` cannot claim the opening of `@Ana Silva` — and so a
        // dictionary's unordered values do not decide which of the two wins.
        highlightMentions(
            in: &text,
            names: mentions.values.sorted { $0.count > $1.count },
            isOwn: isOwn
        )
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
        mentions: [String: String],
        source: ChatTextSource,
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
            if source == .formatted, let escaped = escapedCharacter(characters, at: index) {
                literal.append(escaped)
                index += 2
                continue
            }

            if source == .formatted,
               let token = angleToken(characters, at: index, mentions: mentions, isOwn: isOwn) {
                flushLiteral()
                result.append(token.run)
                index = token.end + 1
                continue
            }

            guard let delimiter = Delimiter(characters[index]),
                  // Re-opening a style already in effect would leave the closing
                  // delimiter with nothing to pair against.
                  delimiter.style.map({ !style.contains($0) }) ?? true,
                  isOpening(characters, at: index),
                  let close = closingIndex(
                      characters,
                      after: index,
                      delimiter: delimiter,
                      source: source
                  )
            else {
                literal.append(characters[index])
                index += 1
                continue
            }

            flushLiteral()
            let inner = Array(characters[(index + 1)..<close])
            if let nested = delimiter.style {
                result.append(
                    parseInline(
                        inner,
                        style: style.union(nested),
                        mentions: mentions,
                        source: source,
                        isOwn: isOwn
                    )
                )
            } else {
                result.append(codeRun(String(inner), isOwn: isOwn))
            }
            index = close + 1
        }

        flushLiteral()
        return result
    }

    // MARK: - `formattedText` forms

    /// The character a backslash at `index` escapes, or nil if it escapes nothing.
    ///
    /// Chat backslashes anything in the body that would otherwise be read as markup, so
    /// a message about `*args` comes back as `\*args` and has to lose the backslash
    /// here — while keeping the asterisk literal, which is the whole point of it.
    ///
    /// Letters and digits are excluded so that a `\n` written in prose, or a Windows
    /// path, survives as typed: Chat had no reason to escape either, and something that
    /// is not an escape should not be eaten as one.
    private static func escapedCharacter(_ characters: [Character], at index: Int) -> Character? {
        guard characters[index] == "\\", index + 1 < characters.count else { return nil }
        let next = characters[index + 1]
        guard !next.isLetter, !next.isNumber, !next.isWhitespace else { return nil }
        return next
    }

    /// The `<…>` construct at `index`, when it is one Chat wrote.
    ///
    /// Nil for anything else, which is the commoner case by far — every `<div>` and
    /// `a < b` in a message reaches here too, and has to come out as typed.
    ///
    /// - Returns: the run to append, and the index of the closing `>`.
    private static func angleToken(
        _ characters: [Character],
        at index: Int,
        mentions: [String: String],
        isOwn: Bool
    ) -> (run: AttributedString, end: Int)? {
        guard characters[index] == "<" else { return nil }

        var close = index + 1
        // A newline before the bracket closes means this was never a token: no form
        // Chat writes spans lines.
        while close < characters.count, characters[close] != ">", characters[close] != "\n" {
            close += 1
        }
        guard close < characters.count, characters[close] == ">" else { return nil }

        let body = String(characters[(index + 1)..<close])
        guard !body.isEmpty else { return nil }

        if body.hasPrefix("users/") {
            guard let name = mentionName(of: body, in: mentions) else { return nil }
            return (mentionRun("@\(name)", isOwn: isOwn), close)
        }

        // `<url|label>`: only the part before the bar is a link, and the label is free
        // text — often the title of the page rather than anything URL-shaped.
        if let bar = body.firstIndex(of: "|") {
            let target = String(body[..<bar])
            let label = String(body[body.index(after: bar)...])
            guard !label.isEmpty, let url = detectedURL(in: target) else { return nil }
            return (linkRun(label, url: url, isOwn: isOwn), close)
        }

        guard let url = detectedURL(in: body) else { return nil }
        return (linkRun(body, url: url, isOwn: isOwn), close)
    }

    /// The URL `raw` is, rather than one it contains: a token is a link only if the
    /// whole of it is.
    private static func detectedURL(in raw: String) -> URL? {
        guard let urlDetector, !raw.isEmpty else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = urlDetector.firstMatch(in: raw, range: range), match.range == range
        else { return nil }
        return match.url
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
    /// belongs to the code rather than closing the bold early. An escaped delimiter is
    /// stepped over for the same reason: `\*` is an asterisk somebody typed, and taking
    /// it for the end of a span would close it in the wrong place.
    private static func closingIndex(
        _ characters: [Character],
        after open: Int,
        delimiter: Delimiter,
        source: ChatTextSource
    ) -> Int? {
        var index = open + 1
        while index < characters.count {
            if source == .formatted, escapedCharacter(characters, at: index) != nil {
                index += 2
                continue
            }
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

    /// Link styling, shared by the detector pass below and `formattedText`'s explicit
    /// `<url|label>`, so a link looks the same however Chat described it.
    private static func linkRun(_ label: String, url: URL, isOwn: Bool) -> AttributedString {
        var run = AttributedString(label)
        run.link = url
        run.underlineStyle = .single
        // Accent-on-accent would vanish inside an own-message bubble.
        run.foregroundColor = isOwn ? .white : .accentColor
        return run
    }

    private static func mentionRun(_ name: String, isOwn: Bool) -> AttributedString {
        var run = AttributedString(name)
        run.font = Font.body.weight(.semibold)
        run.foregroundColor = isOwn ? .white : .accentColor
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
                  !isCode(text[lower..<upper]),
                  // A `<url|label>` whose label happens to read as a URL already points
                  // somewhere Chat chose. Detecting the label would send the reader to
                  // the wrong place.
                  !isLinked(text[lower..<upper])
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

    private static func isLinked(_ slice: AttributedSubstring) -> Bool {
        slice.runs.contains { $0.link != nil }
    }
}
