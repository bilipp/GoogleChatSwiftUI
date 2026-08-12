import Foundation
import SwiftUI
import Testing

@testable import GoogleChatSwiftUI

/// Chat's markup is the one thing in this app with no server-rendered version to
/// compare against — the API hands over raw text and every formatting decision is
/// made here. These pin the syntax down against
/// <https://support.google.com/chat/answer/7649118>.
struct ChatTextRendererTests {
    // MARK: - Helpers

    /// Text with all markup resolved and delimiters removed.
    private func plain(_ raw: String) -> String {
        ChatTextRenderer.plainText(raw)
    }

    private func blocks(_ raw: String) -> [ChatBlock] {
        ChatTextRenderer.blocks(raw)
    }

    /// The single paragraph a message is expected to collapse to.
    private func paragraph(_ raw: String) throws -> AttributedString {
        try paragraph(of: blocks(raw))
    }

    /// The same, for a body that came out of `formattedText` rather than `text`.
    private func formattedParagraph(
        _ raw: String,
        mentions: [String: String] = [:]
    ) throws -> AttributedString {
        try paragraph(
            of: ChatTextRenderer.blocks(raw, mentions: mentions, source: .formatted)
        )
    }

    private func paragraph(of parsed: [ChatBlock]) throws -> AttributedString {
        try #require(parsed.count == 1)
        guard case .paragraph(let text) = parsed[0] else {
            Issue.record("expected one paragraph, got \(parsed)")
            throw CancellationError()
        }
        return text
    }

    /// Whether every character of `substring` carries a bold font. Compared against
    /// `Font.body.bold()` rather than inspecting traits, which `Font` does not expose.
    private func isBold(_ substring: String, in text: AttributedString) -> Bool {
        hasFont(.body.bold(), on: substring, in: text)
    }

    private func hasFont(_ font: Font, on substring: String, in text: AttributedString) -> Bool {
        guard let range = text.range(of: substring) else { return false }
        return text[range].runs.allSatisfy { $0.font == font }
    }

    private func isStruck(_ substring: String, in text: AttributedString) -> Bool {
        guard let range = text.range(of: substring) else { return false }
        return text[range].runs.allSatisfy { $0.strikethroughStyle == .single }
    }

    // MARK: - Inline markup

    @Test func inlineDelimitersAreConsumedAndStyleTheirContents() throws {
        let text = try paragraph("a *bold* b _italic_ c ~struck~ d `code` e")

        #expect(String(text.characters) == "a bold b italic c struck d code e")
        #expect(isBold("bold", in: text))
        #expect(hasFont(.body.italic(), on: "italic", in: text))
        #expect(isStruck("struck", in: text))
        #expect(hasFont(.system(.body, design: .monospaced), on: "code", in: text))
    }

    /// The previous renderer stripped one delimiter at a time and dropped whatever
    /// it had already found, so a doubly-marked span kept only the outer style.
    @Test func stylesNest() throws {
        let text = try paragraph("*_both_*")

        #expect(String(text.characters) == "both")
        #expect(hasFont(.body.bold().italic(), on: "both", in: text))
    }

    /// A delimiter with no partner is ordinary punctuation. It must not swallow the
    /// rest of the message, nor disable the styling of well-formed spans beside it.
    @Test func unmatchedDelimitersStayLiteral() throws {
        let text = try paragraph("2 * 3 = 6, and *this* is bold")

        #expect(String(text.characters) == "2 * 3 = 6, and this is bold")
        #expect(isBold("this", in: text))
    }

    /// Identifiers and URL paths are full of underscores that are not italics.
    @Test func markupInsideAWordIsLeftAlone() {
        #expect(plain("call snake_case_name here") == "call snake_case_name here")
        #expect(plain("see https://example.com/a_b_c now") == "see https://example.com/a_b_c now")
        #expect(plain("2*3*4") == "2*3*4")
    }

    @Test func emptySpansAreNotMarkup() {
        #expect(plain("nothing ** here") == "nothing ** here")
        #expect(plain("__") == "__")
    }

    /// Markup inside a code span is sample text, not formatting.
    @Test func codeSpansSuppressOtherMarkup() throws {
        let text = try paragraph("use `*not bold*` please")

        #expect(String(text.characters) == "use *not bold* please")
        #expect(hasFont(.system(.body, design: .monospaced), on: "*not bold*", in: text))
    }

    /// The bold span has to reach past the code, rather than letting the `*` that
    /// belongs to the code sample close it early.
    @Test func aCodeSpanInsideAStyledSpanDoesNotEndIt() throws {
        let text = try paragraph("*see `a*b` here*")

        #expect(String(text.characters) == "see a*b here")
        #expect(isBold("see ", in: text))
        #expect(isBold(" here", in: text))
    }

    /// A link inside a code span is an example, so it must not become clickable.
    @Test func urlsInsideCodeAreNotLinkified() throws {
        let text = try paragraph("`https://example.com` and https://example.org")

        let code = try #require(text.range(of: "https://example.com"))
        #expect(text[code].runs.allSatisfy { $0.link == nil })

        let bare = try #require(text.range(of: "https://example.org"))
        #expect(text[bare].runs.contains { $0.link != nil })
    }

    // MARK: - Block formats

    @Test func fencedBlocksKeepTheirContentsVerbatim() throws {
        let parsed = blocks("before\n```\nlet x = *y*\n```\nafter")

        #expect(parsed.count == 3)
        guard case .paragraph(let before) = parsed[0],
              case .codeBlock(let language, let code) = parsed[1],
              case .paragraph(let after) = parsed[2]
        else {
            Issue.record("expected paragraph, code, paragraph — got \(parsed)")
            return
        }
        #expect(String(before.characters) == "before")
        #expect(language == nil)
        #expect(code == "let x = *y*")
        #expect(String(after.characters) == "after")
    }

    /// Chat accepts a fence that opens and closes within one line.
    @Test func aFenceOnASingleLineStillMakesABlock() {
        let parsed = blocks("run ```make test``` now")

        #expect(parsed.count == 3)
        if case .codeBlock(let language, let code) = parsed[1] {
            // "make" is a word of the command, not a tag: nothing follows it on the
            // line, so there is no tag to read.
            #expect(language == nil)
            #expect(code == "make test")
        } else {
            Issue.record("expected a code block in the middle, got \(parsed)")
        }
    }

    // MARK: - Language tags

    /// A tagged fence is not Chat syntax, but it arrives constantly from editors and
    /// other clients. Left unparsed the tag shows up as a first line of code.
    @Test func aLanguageTagIsReadOffTheFenceAndNotShownAsCode() throws {
        let parsed = blocks("```swift\nlet x = 1\n```")

        try #require(parsed.count == 1)
        guard case .codeBlock(let language, let code) = parsed[0] else {
            Issue.record("expected a code block, got \(parsed)")
            return
        }
        #expect(language == .swift)
        #expect(code == "let x = 1")
    }

    @Test(arguments: [
        ("js", CodeLanguage.javaScript), ("JS", .javaScript), ("py", .python),
        ("yml", .yaml), ("objective-c", .objectiveC), ("c++", .cFamily)
    ])
    func languageAliasesResolveToOneLanguage(tag: String, expected: CodeLanguage) throws {
        let parsed = blocks("```\(tag)\nx\n```")

        guard case .codeBlock(let language, let code) = parsed.first else {
            Issue.record("expected a code block, got \(parsed)")
            return
        }
        #expect(language == expected)
        #expect(code == "x")
    }

    /// The line has to be a language we know, because "any single word" would eat the
    /// first line of every fence that opens with one — and losing a line of someone's
    /// code is worse than leaving an unusual language unlabelled.
    @Test func anUnrecognisedFirstLineStaysPartOfTheCode() throws {
        let parsed = blocks("```\nbegin\n  work()\nend\n```")

        guard case .codeBlock(let language, let code) = parsed.first else {
            Issue.record("expected a code block, got \(parsed)")
            return
        }
        #expect(language == nil)
        #expect(code == "begin\n  work()\nend")
    }

    /// A fence whose only content is a language word is that word, not an empty block
    /// with a label.
    @Test func aTagWithNoCodeUnderItIsJustCode() throws {
        let parsed = blocks("```swift```")

        guard case .codeBlock(let language, let code) = parsed.first else {
            Issue.record("expected a code block, got \(parsed)")
            return
        }
        #expect(language == nil)
        #expect(code == "swift")
    }

    /// The tag is markup, so the text-only rendering must not carry it either.
    @Test func plainTextDropsTheLanguageTag() {
        #expect(plain("```swift\nlet x = 1\n```") == "let x = 1")
    }

    @Test func anUnclosedFenceIsLiteralText() {
        #expect(plain("look ```here") == "look ```here")
    }

    @Test func consecutiveQuoteLinesFormOneBlock() {
        let parsed = blocks("> first\n> second\nnot quoted")

        #expect(parsed.count == 2)
        if case .quote(let lines) = parsed[0] {
            #expect(lines.map { String($0.characters) } == ["first", "second"])
        } else {
            Issue.record("expected a quote block, got \(parsed)")
        }
    }

    @Test func bothBulletMarkersAreRecognisedAndMerge() {
        let parsed = blocks("- dash\n* asterisk")

        #expect(parsed.count == 1)
        if case .bulletList(let items) = parsed[0] {
            #expect(items.map { String($0.characters) } == ["dash", "asterisk"])
        } else {
            Issue.record("expected one bullet list, got \(parsed)")
        }
    }

    /// The space after the marker is the only thing separating a bullet from a line
    /// that happens to start with bold — get this wrong and every `*bold*` opening a
    /// line turns into a list item.
    @Test func aLineStartingWithBoldIsNotABullet() throws {
        let text = try paragraph("*heads up* everyone")

        #expect(String(text.characters) == "heads up everyone")
        #expect(isBold("heads up", in: text))
    }

    @Test func inlineMarkupAppliesInsideBulletsAndQuotes() {
        let parsed = blocks("- a *bold* item\n\n> a _quoted_ line")

        #expect(parsed.count == 2)
        if case .bulletList(let items) = parsed[0], let first = items.first {
            #expect(String(first.characters) == "a bold item")
            #expect(isBold("bold", in: first))
        } else {
            Issue.record("expected a bullet list first, got \(parsed)")
        }
        if case .quote(let lines) = parsed[1], let first = lines.first {
            #expect(String(first.characters) == "a quoted line")
            #expect(hasFont(.body.italic(), on: "quoted", in: first))
        } else {
            Issue.record("expected a quote second, got \(parsed)")
        }
    }

    /// Line breaks a person typed inside a paragraph are theirs to keep; the blank
    /// lines that only separate blocks are not.
    @Test func paragraphsKeepInteriorLineBreaks() throws {
        let text = try paragraph("one\ntwo\n\nthree")

        #expect(String(text.characters) == "one\ntwo\n\nthree")
    }

    // MARK: - Mentions

    @Test func mentionsAreHighlightedOutsideCodeSpans() throws {
        let parsed = ChatTextRenderer.blocks(
            "hi @Ada Lovelace",
            mentions: ["users/1": "Ada Lovelace"]
        )
        guard case .paragraph(let text) = try #require(parsed.first) else {
            Issue.record("expected a paragraph, got \(parsed)")
            return
        }

        let range = try #require(text.range(of: "@Ada Lovelace"))
        #expect(text[range].runs.allSatisfy { $0.foregroundColor == .accentColor })
    }

    // MARK: - Plain text

    /// Notifications and the menu bar cannot render any of this, so what reaches
    /// them must carry no markup characters at all.
    @Test func plainTextStripsEveryFormat() {
        let raw = "*bold* and `code`\n> quoted\n- item\n```\nfenced\n```"

        #expect(plain(raw) == "bold and code\nquoted\n• item\nfenced")
    }

    @Test func unformattedTextSurvivesUntouched() {
        let raw = "Just a normal sentence, with punctuation — and an em dash."

        #expect(plain(raw) == raw)
    }

    // MARK: - Choosing a body

    /// The bug these were written for: Chat resolves formatting as a message is posted
    /// and serves `text` with the markup taken back out, so a message about
    /// `` `a_tool_name` `` reaches `text` as bare prose and rendering it can only ever
    /// show bare prose. `formattedText` is the copy that still knows.
    @Test func formattedCopyIsPreferredOverThePlainOne() {
        let body = ChatTextRenderer.body(
            formatted: "call `module_entities_get_for_module` first",
            plain: "call module_entities_get_for_module first",
            mentions: [:]
        )

        #expect(body.source == .formatted)
        #expect(body.text.contains("`"))
    }

    @Test func plainCopyIsUsedWhenChatSentNoFormattedOne() {
        let body = ChatTextRenderer.body(formatted: nil, plain: "typed just now", mentions: [:])

        #expect(body.source == .plain)
        #expect(body.text == "typed just now")
    }

    /// A mention this app cannot name yet would render as `<users/123>`, which is worse
    /// than a message that lost its backticks. The plain copy has the name written out,
    /// so it stands in until the directory answers.
    @Test func unnamedMentionFallsBackToThePlainCopy() {
        let body = ChatTextRenderer.body(
            formatted: "<users/1> see `this`",
            plain: "@Ada Lovelace see this",
            mentions: [:]
        )

        #expect(body.source == .plain)
        #expect(body.text == "@Ada Lovelace see this")
    }

    @Test func namedMentionKeepsTheFormattedCopy() {
        let body = ChatTextRenderer.body(
            formatted: "<users/1> see `this`",
            plain: "@Ada Lovelace see this",
            mentions: ["users/1": "Ada Lovelace"]
        )

        #expect(body.source == .formatted)
    }

    /// `users/all` is Chat's own name for the room and is in nobody's directory, so it
    /// must not be the thing that sends a message back to its plain copy.
    @Test func everyoneMentionNeedsNoDirectoryEntry() throws {
        let body = ChatTextRenderer.body(
            formatted: "<users/all> heads up",
            plain: "@all heads up",
            mentions: [:]
        )
        #expect(body.source == .formatted)

        let text = try formattedParagraph("<users/all> heads up")
        #expect(String(text.characters) == "@all heads up")
    }

    // MARK: - `formattedText` forms

    @Test func mentionTokensAreRenderedAsNames() throws {
        let text = try formattedParagraph(
            "<users/1> can you look?",
            mentions: ["users/1": "Ada Lovelace"]
        )

        #expect(String(text.characters) == "@Ada Lovelace can you look?")
        let range = try #require(text.range(of: "@Ada Lovelace"))
        #expect(text[range].runs.allSatisfy { $0.foregroundColor == .accentColor })
    }

    /// Chat backslashes anything in the body that would otherwise read as markup. The
    /// escape has to go and the character it protected has to stay literal — including
    /// when it is a delimiter that would otherwise close a span in the wrong place.
    @Test func escapesResolveToTheirCharacter() throws {
        let text = try formattedParagraph("*\\[InnoMCP\\] shipped* with \\*args")

        #expect(String(text.characters) == "[InnoMCP] shipped with *args")
        #expect(isBold("[InnoMCP] shipped", in: text))
    }

    /// Only Chat's own escapes. A backslash in prose — a regex, a path — is a character
    /// somebody typed and stays one.
    @Test func backslashesBeforeWordCharactersAreLiteral() throws {
        let text = try formattedParagraph("matches \\d+ in C:\\temp")

        #expect(String(text.characters) == "matches \\d+ in C:\\temp")
    }

    @Test func customHyperlinksLinkTheirLabel() throws {
        let text = try formattedParagraph("see <https://example.com/spec|the spec> for more")

        #expect(String(text.characters) == "see the spec for more")
        let range = try #require(text.range(of: "the spec"))
        #expect(text[range].runs.allSatisfy { $0.link == URL(string: "https://example.com/spec") })
    }

    @Test func bracketedAddressesBecomeLinks() throws {
        let text = try formattedParagraph("ask <ada@example.com>")

        #expect(String(text.characters) == "ask ada@example.com")
        let range = try #require(text.range(of: "ada@example.com"))
        #expect(text[range].runs.allSatisfy { $0.link == URL(string: "mailto:ada@example.com") })
    }

    /// Angle brackets are ordinary punctuation far more often than they are syntax.
    @Test func anglesThatAreNotTokensStayLiteral() throws {
        let text = try formattedParagraph("wrap it in a <div> when a < b")

        #expect(String(text.characters) == "wrap it in a <div> when a < b")
    }

    /// None of the above is syntax in `text`, which is what a locally composed message
    /// and every row cached before this still renders from.
    @Test func plainBodiesKeepFormattedOnlyFormsLiteral() throws {
        let text = try paragraph("send <users/1> a \\[bracket\\]")

        #expect(String(text.characters) == "send <users/1> a \\[bracket\\]")
    }

    // MARK: - Editing

    /// The edit field starts from the formatted body, so fixing a typo posts the
    /// formatting back rather than flattening the message. Mentions are the exception:
    /// nobody can edit around `<users/1>`, and the send path encodes the name again.
    @Test func editableBodyKeepsMarkupAndNamesMentions() {
        let body = ChatMessageBody(
            text: "<users/1> the `parser` is *done*",
            source: .formatted
        )

        let draft = ChatTextRenderer.editable(body, mentions: ["users/1": "Ada Lovelace"])

        #expect(draft == "@Ada Lovelace the `parser` is *done*")
    }
}
