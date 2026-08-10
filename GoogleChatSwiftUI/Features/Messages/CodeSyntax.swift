import SwiftUI

/// What a run of code turned out to be.
///
/// Coarse on purpose. An editor can tell a local type from a framework one because it
/// has a symbol table; a chat transcript has forty characters of someone else's code
/// and no idea what it refers to, so the kinds here are only the ones a lexer can be
/// sure of.
nonisolated enum CodeToken: Sendable, Hashable {
    case plain
    case keyword
    case type
    /// A name being called or declared as a function — and, in shell, the command at
    /// the head of a line.
    case function
    case string
    case number
    case comment
    /// `@State`, a Python decorator, a C preprocessor line.
    case attribute
    /// A key: JSON and YAML mapping keys, CSS property names, HTTP header names.
    case property
    /// An element name in markup.
    case tag
    case added
    case removed
}

/// One stretch of code that shares a kind. Concatenating every `text` in order
/// reproduces the input exactly, which is what lets the view build styled text without
/// juggling string indices.
nonisolated struct CodeRun: Sendable, Hashable {
    let text: String
    let token: CodeToken
}

/// The colours a code block is drawn in.
///
/// Values are Xcode's own Default (Light) and Default (Dark) themes, read out of
/// `SourceEditor.framework`, rather than a palette invented here: the point of
/// highlighting is that the reader recognises the colours, and on this platform these
/// are the ones they already know.
///
/// `plain` is set explicitly rather than inherited. The bubble hands its own text colour
/// down — white inside an own message — and unhighlighted code that took it would go
/// invisible on the panel.
nonisolated struct CodeSyntaxPalette: Sendable {
    let plain: Color
    let keyword: Color
    let type: Color
    let function: Color
    let string: Color
    let number: Color
    let comment: Color
    let attribute: Color
    let property: Color
    let added: Color
    let removed: Color

    func color(for token: CodeToken) -> Color {
        switch token {
        case .plain: plain
        case .keyword: keyword
        case .type: type
        case .function: function
        case .string: string
        case .number: number
        case .comment: comment
        case .attribute: attribute
        case .property: property
        case .tag: keyword
        case .added: added
        case .removed: removed
        }
    }

    /// Xcode's Default (Light), on a near-white panel.
    static let light = CodeSyntaxPalette(
        // Xcode's plain is pure black at 85%; flattened here, since the panel it sits
        // on is not always the pure white it assumes.
        plain: Color(hex: 0x26262B),
        keyword: Color(hex: 0x9B2393),
        type: Color(hex: 0x3900A0),
        function: Color(hex: 0x326D74),
        string: Color(hex: 0xC41A16),
        number: Color(hex: 0x1C00CF),
        comment: Color(hex: 0x5D6C79),
        attribute: Color(hex: 0x815F03),
        property: Color(hex: 0x0F68A0),
        // Diff has no Xcode equivalent — these are the semantic pair, darkened enough
        // to hold their own against a light panel.
        added: Color(hex: 0x1A7F45),
        removed: Color(hex: 0xB3261E)
    )

    /// Xcode's Default (Dark), on a `#1F1F24`-ish panel.
    static let dark = CodeSyntaxPalette(
        plain: Color(hex: 0xE8E8ED),
        keyword: Color(hex: 0xFC5FA3),
        type: Color(hex: 0xD0A8FF),
        function: Color(hex: 0x67B7A4),
        string: Color(hex: 0xFC6A5D),
        number: Color(hex: 0xD0BF69),
        comment: Color(hex: 0x7D8B99),
        attribute: Color(hex: 0xBF8555),
        property: Color(hex: 0x41A1C0),
        added: Color(hex: 0x5DD98C),
        removed: Color(hex: 0xFF7B72)
    )
}

extension Color {
    /// Theme values arrive as hex, and writing them as three doubles each would hide
    /// what they are.
    ///
    /// `nonisolated` so the palettes, which are static values on a nonisolated type,
    /// can be built with it.
    nonisolated init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Highlights code.
///
/// A lexer rather than a parser: it reads left to right and never builds a tree, which
/// is all colouring needs and is what keeps one malformed snippet — and a chat is full
/// of malformed snippets, pasted mid-function — from taking the rest of the block with
/// it. Every branch that consumes to a terminator falls back to end-of-input when the
/// terminator never comes.
nonisolated enum CodeSyntax {
    /// Styled code, or the plain string when there is no language to go on.
    static func attributed(
        _ code: String,
        language: CodeLanguage?,
        palette: CodeSyntaxPalette
    ) -> AttributedString {
        guard let language else {
            // Still coloured, just uniformly: the bubble's white text colour would be
            // invisible on the panel.
            var unhighlighted = AttributedString(code)
            unhighlighted.foregroundColor = palette.plain
            return unhighlighted
        }
        var result = AttributedString()
        for run in runs(code, language: language) where !run.text.isEmpty {
            var piece = AttributedString(run.text)
            piece.foregroundColor = palette.color(for: run.token)
            result.append(piece)
        }
        return result
    }

    /// The lexed runs, in order.
    static func runs(_ code: String, language: CodeLanguage) -> [CodeRun] {
        switch language {
        case .diff: diffRuns(code)
        case .markup: markupRuns(code)
        // Prose in a code block is still prose: there is nothing here to colour.
        case .markdown, .text: [CodeRun(text: code, token: .plain)]
        default: lex(code, grammar(for: language))
        }
    }

    // MARK: - Grammar

    /// The knobs the general lexer is driven by. Everything that differs between
    /// languages lives here, so there is one lexer rather than twenty.
    private struct Grammar {
        var keywords: Set<String> = []
        /// Matched against the lowercased word, for languages people shout in.
        var caseInsensitiveKeywords = false
        var lineComments: [String] = []
        var blockComments: [(open: String, close: String)] = []
        var stringDelimiters: [Character] = ["\""]
        /// Triple-quoted strings: Swift's `"""`, Python's `"""` and `'''`.
        var tripleQuoted = false
        /// `'` opens a string only when it reads as `'x'` — otherwise it is a Rust
        /// lifetime or an apostrophe in a comment, and treating it as a quote would
        /// paint the rest of the line red.
        var singleQuoteIsCharLiteral = false
        /// `@` before a name, or `#` before a preprocessor directive.
        var attributeSigils: [Character] = []
        /// `$NAME` and `${NAME}`.
        var dollarVariables = false
        /// A capitalised word is a type. True for languages that follow the convention
        /// and false for the ones where it just means someone held shift.
        var capitalizedIsType = true
        /// A quoted string followed by `:` is a key, as in JSON.
        var stringKeyBeforeColon = false
        /// A bare word at the head of a line followed by this character is a key: `:`
        /// for YAML and CSS, `=` for TOML.
        var keyTerminator: Character?
        /// The first word of a line is the command being run.
        var commandFirstWord = false
        /// A name followed by `(` is a function.
        var functionCalls = true
    }

    private static func words(_ list: String) -> Set<String> {
        Set(list.split(separator: " ").map(String.init))
    }

    private static func grammar(for language: CodeLanguage) -> Grammar {
        switch language {
        case .swift:
            Grammar(
                keywords: words("""
                    actor any as associatedtype async await borrowing break case catch \
                    class consume continue convenience defer deinit didSet do dynamic \
                    each else enum extension fallthrough false fileprivate final for \
                    func get guard if import in indirect infix init inout internal is \
                    isolated lazy let macro mutating nil nonisolated nonmutating open \
                    operator override postfix prefix private protocol public repeat \
                    required rethrows return self set some static struct subscript \
                    super switch throw throws true try typealias unowned var weak \
                    where while willSet yield
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                tripleQuoted: true,
                attributeSigils: ["@", "#"]
            )
        case .objectiveC:
            Grammar(
                keywords: words("""
                    auto BOOL break case char const continue default do double else \
                    enum extern float for goto id if inline instancetype int long nil \
                    NO register return self short signed sizeof static struct super \
                    switch typedef union unsigned void volatile while YES atomic \
                    nonatomic strong weak copy assign readonly readwrite nullable nonnull
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                singleQuoteIsCharLiteral: true,
                attributeSigils: ["@", "#"]
            )
        case .cFamily:
            Grammar(
                keywords: words("""
                    alignas alignof auto bool break case catch char class const \
                    consteval constexpr const_cast continue decltype default delete do \
                    double dynamic_cast else enum explicit export extern false float \
                    for friend goto if inline int long mutable namespace new noexcept \
                    nullptr operator private protected public register reinterpret_cast \
                    return short signed sizeof static static_assert static_cast struct \
                    switch template this throw true try typedef typeid typename union \
                    unsigned using virtual void volatile while
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                singleQuoteIsCharLiteral: true,
                attributeSigils: ["#"]
            )
        case .csharp:
            Grammar(
                keywords: words("""
                    abstract as async await base bool break byte case catch char \
                    checked class const continue decimal default delegate do double \
                    dynamic else enum event explicit extern false finally fixed float \
                    for foreach get goto if implicit in int interface internal is lock \
                    long namespace new null object operator out override params private \
                    protected public readonly ref return sbyte sealed set short sizeof \
                    static string struct switch this throw true try typeof uint ulong \
                    unchecked unsafe ushort using var virtual void volatile where while \
                    yield
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                singleQuoteIsCharLiteral: true,
                attributeSigils: ["#"]
            )
        case .java, .scala:
            Grammar(
                keywords: words("""
                    abstract assert boolean break byte case catch char class const \
                    continue default do double else enum extends false final finally \
                    float for given goto if implements implicit import instanceof int \
                    interface lazy long match native new null object override package \
                    permits private protected public record return sealed short static \
                    strictfp super switch synchronized this throw throws trait \
                    transient true try using val var void volatile while with yield
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                singleQuoteIsCharLiteral: true,
                attributeSigils: ["@"]
            )
        case .kotlin:
            Grammar(
                keywords: words("""
                    abstract actual annotation as break by catch class companion const \
                    constructor continue crossinline data do else enum expect external \
                    false final finally for fun get if import in infix init inline \
                    inner interface internal is it lateinit null object open operator \
                    out override package private protected public reified return sealed \
                    set super suspend tailrec this throw true try typealias val var \
                    vararg when where while
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                singleQuoteIsCharLiteral: true,
                attributeSigils: ["@"]
            )
        case .javaScript, .typeScript:
            Grammar(
                keywords: words("""
                    abstract any as asserts async await bigint boolean break case catch \
                    class const constructor continue debugger declare default delete do \
                    else enum export extends false finally for from function get if \
                    implements import in infer instanceof interface is keyof let new \
                    null number object of package private protected public readonly \
                    return satisfies set static string super switch symbol this throw \
                    true try type typeof undefined unknown var void while with yield
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                stringDelimiters: ["\"", "'", "`"],
                attributeSigils: ["@"]
            )
        case .python:
            Grammar(
                keywords: words("""
                    and as assert async await break case class continue def del elif \
                    else except False finally for from global if import in is lambda \
                    match None nonlocal not or pass raise return self True try while \
                    with yield
                    """),
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                tripleQuoted: true,
                attributeSigils: ["@"]
            )
        case .ruby:
            Grammar(
                keywords: words("""
                    alias and attr_accessor attr_reader attr_writer begin break case \
                    class def defined do else elsif end ensure false for if in module \
                    next nil not or private protected public raise redo require \
                    require_relative rescue retry return self super then true undef \
                    unless until when while yield
                    """),
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                attributeSigils: ["@"]
            )
        case .go:
            Grammar(
                keywords: words("""
                    append bool break byte cap case chan const continue copy default \
                    defer delete else error fallthrough false float64 for func go goto \
                    if import int int64 interface iota len make map new nil package \
                    panic range recover return rune select string struct switch true \
                    type var
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                stringDelimiters: ["\"", "`"],
                singleQuoteIsCharLiteral: true
            )
        case .rust:
            Grammar(
                keywords: words("""
                    as async await break const continue crate dyn else enum Err extern \
                    false fn for if impl in let loop match mod move mut None Ok Option \
                    pub ref Result return Self self Some static str String struct super \
                    trait true type unsafe use Vec where while
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                singleQuoteIsCharLiteral: true
            )
        case .php:
            Grammar(
                keywords: words("""
                    abstract and array as break callable case catch class clone const \
                    continue declare default do echo else elseif empty enum extends \
                    final finally fn for foreach function global if implements include \
                    include_once instanceof insteadof interface isset list match \
                    namespace new null or print private protected public readonly \
                    require require_once return static switch throw trait true try \
                    unset use var while yield
                    """),
                lineComments: ["//", "#"],
                blockComments: [("/*", "*/")],
                stringDelimiters: ["\"", "'"],
                dollarVariables: true
            )
        case .lua:
            Grammar(
                keywords: words("""
                    and break do else elseif end false for function goto if in local \
                    nil not or repeat return then true until while
                    """),
                lineComments: ["--"],
                blockComments: [("--[[", "]]")],
                stringDelimiters: ["\"", "'"]
            )
        case .shell:
            Grammar(
                keywords: words("""
                    alias break case continue coproc declare do done elif else esac \
                    eval exec exit export fi for function if in local readonly return \
                    select set source then time trap typeset unalias unset until while
                    """),
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                dollarVariables: true,
                capitalizedIsType: false,
                commandFirstWord: true,
                functionCalls: false
            )
        case .sql:
            Grammar(
                keywords: words("""
                    add all alter and as asc avg begin between by case column commit \
                    count create cross default delete desc distinct drop else end \
                    exists foreign from full group having if in index inner insert \
                    into is join key left like limit max min not null offset on or \
                    order outer primary references returning right rollback select set \
                    sum table then transaction union unique update values when where \
                    with
                    """),
                caseInsensitiveKeywords: true,
                lineComments: ["--"],
                blockComments: [("/*", "*/")],
                stringDelimiters: ["'", "\""],
                capitalizedIsType: false
            )
        case .json:
            Grammar(
                keywords: words("true false null"),
                // A comment is not JSON, but JSON5 and every editor's "jsonc" allow it
                // and people paste from those.
                lineComments: ["//"],
                capitalizedIsType: false,
                stringKeyBeforeColon: true,
                functionCalls: false
            )
        case .yaml:
            Grammar(
                keywords: words("true false null yes no on off"),
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                capitalizedIsType: false,
                keyTerminator: ":",
                functionCalls: false
            )
        case .toml:
            Grammar(
                keywords: words("true false"),
                lineComments: ["#", ";"],
                stringDelimiters: ["\"", "'"],
                capitalizedIsType: false,
                keyTerminator: "=",
                functionCalls: false
            )
        case .css:
            Grammar(
                keywords: words("important inherit initial none unset var"),
                blockComments: [("/*", "*/")],
                stringDelimiters: ["\"", "'"],
                attributeSigils: ["@"],
                capitalizedIsType: false,
                keyTerminator: ":"
            )
        case .graphQL:
            Grammar(
                keywords: words("""
                    directive enum extend false fragment implements input interface \
                    mutation null on query scalar schema subscription true type union
                    """),
                lineComments: ["#"],
                keyTerminator: ":",
                functionCalls: false
            )
        case .proto:
            Grammar(
                keywords: words("""
                    bool bytes double enum extend false fixed32 fixed64 float import \
                    int32 int64 map message oneof option optional package repeated \
                    required reserved returns rpc service string syntax true uint32 \
                    uint64
                    """),
                lineComments: ["//"],
                blockComments: [("/*", "*/")]
            )
        case .makefile:
            Grammar(
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                dollarVariables: true,
                capitalizedIsType: false,
                keyTerminator: ":",
                functionCalls: false
            )
        case .dockerfile:
            Grammar(
                keywords: words("""
                    ADD ARG CMD COPY ENTRYPOINT ENV EXPOSE FROM HEALTHCHECK LABEL \
                    ONBUILD RUN SHELL STOPSIGNAL USER VOLUME WORKDIR as
                    """),
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                dollarVariables: true,
                capitalizedIsType: false,
                functionCalls: false
            )
        case .http:
            Grammar(
                keywords: words("CONNECT DELETE GET HEAD OPTIONS PATCH POST PUT TRACE"),
                stringDelimiters: ["\""],
                capitalizedIsType: false,
                keyTerminator: ":",
                functionCalls: false
            )
        case .diff, .markup, .markdown, .text:
            // Lexed elsewhere; a grammar would never be asked for.
            Grammar()
        }
    }

    // MARK: - General lexer

    private static func lex(_ code: String, _ grammar: Grammar) -> [CodeRun] {
        let characters = Array(code)
        var runs: [CodeRun] = []
        var plain = ""
        var index = 0
        /// Only whitespace — or a YAML list dash — seen since the last newline.
        var atLineStart = true
        /// The next word is the command being run: true at the start of a line and
        /// after a pipe or separator.
        var atCommandStart = true

        func flush() {
            guard !plain.isEmpty else { return }
            runs.append(CodeRun(text: plain, token: .plain))
            plain = ""
        }
        func emit(_ range: Range<Int>, _ token: CodeToken) {
            flush()
            runs.append(CodeRun(text: String(characters[range]), token: token))
        }
        func matches(_ needle: String, at start: Int) -> Bool {
            let needleCharacters = Array(needle)
            guard start + needleCharacters.count <= characters.count else { return false }
            return Array(characters[start..<(start + needleCharacters.count)]) == needleCharacters
        }
        /// The next character that is not a space or tab, for the "is this a key?" and
        /// "is this a call?" questions.
        func nextSignificant(from start: Int) -> Character? {
            var scan = start
            while scan < characters.count, characters[scan] == " " || characters[scan] == "\t" {
                scan += 1
            }
            return scan < characters.count ? characters[scan] : nil
        }
        func isIdentifier(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\n" {
                plain.append(character)
                atLineStart = true
                atCommandStart = true
                index += 1
                continue
            }

            if grammar.lineComments.contains(where: { matches($0, at: index) }) {
                // A `#` mid-line is a comment in shell but a fragment in a URL, and
                // `//` opens one everywhere except inside one. Not worth chasing: in a
                // chat snippet the common case is a comment.
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                emit(index..<end, .comment)
                index = end
                continue
            }

            if let delimiters = grammar.blockComments.first(where: { matches($0.open, at: index) }) {
                var end = index + delimiters.open.count
                while end < characters.count, !matches(delimiters.close, at: end) { end += 1 }
                end = min(characters.count, end + delimiters.close.count)
                emit(index..<end, .comment)
                index = end
                atLineStart = false
                continue
            }

            if grammar.stringDelimiters.contains(character),
               character != "'" || !grammar.singleQuoteIsCharLiteral
                   || isCharLiteral(characters, at: index) {
                let end = stringEnd(characters, from: index, grammar: grammar)
                // A quoted key is a key first: that is the whole of JSON's structure.
                let isKey = grammar.stringKeyBeforeColon && nextSignificant(from: end) == ":"
                emit(index..<end, isKey ? .property : .string)
                index = end
                atLineStart = false
                atCommandStart = false
                continue
            }

            if character.isNumber, index == 0 || !isIdentifier(characters[index - 1]) {
                var end = index
                while end < characters.count,
                      characters[end].isHexDigit || "xXoObB._".contains(characters[end]) {
                    end += 1
                }
                emit(index..<end, .number)
                index = end
                atLineStart = false
                atCommandStart = false
                continue
            }

            if grammar.dollarVariables, character == "$", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "{" {
                    var end = index + 2
                    while end < characters.count, characters[end] != "}" { end += 1 }
                    end = min(characters.count, end + 1)
                    emit(index..<end, .property)
                    index = end
                    atLineStart = false
                    continue
                }
                if isIdentifier(next) {
                    var end = index + 1
                    while end < characters.count, isIdentifier(characters[end]) { end += 1 }
                    emit(index..<end, .property)
                    index = end
                    atLineStart = false
                    atCommandStart = false
                    continue
                }
            }

            if grammar.attributeSigils.contains(character), index + 1 < characters.count,
               characters[index + 1].isLetter || characters[index + 1] == "_" {
                var end = index + 1
                while end < characters.count, isIdentifier(characters[end]) { end += 1 }
                emit(index..<end, .attribute)
                index = end
                atLineStart = false
                atCommandStart = false
                continue
            }

            if character.isLetter || character == "_" {
                var end = index
                while end < characters.count, isIdentifier(characters[end]) { end += 1 }
                let word = String(characters[index..<end])
                let token = classify(
                    word,
                    grammar: grammar,
                    atLineStart: atLineStart,
                    atCommandStart: atCommandStart,
                    following: nextSignificant(from: end)
                )
                if token == .plain {
                    plain += word
                } else {
                    emit(index..<end, token)
                }
                index = end
                atLineStart = false
                atCommandStart = false
                continue
            }

            // A pipe or a separator starts a new command; a leading `-` or `$` prompt
            // does not end the run of whitespace that counts as the head of a line.
            if character == "|" || character == ";" || character == "&" {
                atCommandStart = true
            } else if character != " " && character != "\t" && character != "-"
                && character != "$" && character != "%" {
                atLineStart = false
            }
            plain.append(character)
            index += 1
        }

        flush()
        return runs
    }

    private static func classify(
        _ word: String,
        grammar: Grammar,
        atLineStart: Bool,
        atCommandStart: Bool,
        following: Character?
    ) -> CodeToken {
        if grammar.keywords.contains(grammar.caseInsensitiveKeywords ? word.lowercased() : word) {
            return .keyword
        }
        if let terminator = grammar.keyTerminator, atLineStart, following == terminator {
            return .property
        }
        if grammar.commandFirstWord, atCommandStart { return .function }
        if grammar.capitalizedIsType, word.first?.isUppercase == true { return .type }
        if grammar.functionCalls, following == "(" { return .function }
        return .plain
    }

    /// One past the closing quote, or the end of the input when the string never closes
    /// — which happens constantly in a chat, where snippets are cut mid-line.
    private static func stringEnd(
        _ characters: [Character],
        from open: Int,
        grammar: Grammar
    ) -> Int {
        let quote = characters[open]
        let isTriple = grammar.tripleQuoted
            && open + 2 < characters.count
            && characters[open + 1] == quote
            && characters[open + 2] == quote
        let width = isTriple ? 3 : 1
        var index = open + width

        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                index += 2
                continue
            }
            if character == quote {
                if !isTriple { return index + 1 }
                if index + 2 < characters.count,
                   characters[index + 1] == quote, characters[index + 2] == quote {
                    return index + 3
                }
            }
            // A single-quoted string does not survive a line break in any language that
            // matters here, and letting it run turns the rest of the block red.
            if character == "\n", !isTriple { return index }
            index += 1
        }
        return characters.count
    }

    /// Whether the `'` at `index` opens a character literal — `'a'`, `'\n'` — as
    /// opposed to a Rust lifetime or a stray apostrophe.
    private static func isCharLiteral(_ characters: [Character], at index: Int) -> Bool {
        if index + 2 < characters.count, characters[index + 1] == "\\" { return true }
        guard index + 2 < characters.count else { return false }
        return characters[index + 2] == "'"
    }

    // MARK: - Diff

    /// Line-based, because that is what a diff is: the first character of a line decides
    /// the whole line, and nothing inside it means anything else.
    private static func diffRuns(_ code: String) -> [CodeRun] {
        var runs: [CodeRun] = []
        let lines = code.components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() {
            let token: CodeToken
            if line.hasPrefix("@@") {
                token = .property
            } else if line.hasPrefix("+++") || line.hasPrefix("---")
                || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                token = .comment
            } else if line.hasPrefix("+") {
                token = .added
            } else if line.hasPrefix("-") {
                token = .removed
            } else {
                token = .plain
            }
            runs.append(CodeRun(text: line, token: token))
            if offset < lines.count - 1 { runs.append(CodeRun(text: "\n", token: .plain)) }
        }
        return runs
    }

    // MARK: - Markup

    /// Tags, attribute names and attribute values; everything between tags is text.
    private static func markupRuns(_ code: String) -> [CodeRun] {
        let characters = Array(code)
        var runs: [CodeRun] = []
        var plain = ""
        var index = 0

        func flush() {
            guard !plain.isEmpty else { return }
            runs.append(CodeRun(text: plain, token: .plain))
            plain = ""
        }
        func emit(_ range: Range<Int>, _ token: CodeToken) {
            flush()
            runs.append(CodeRun(text: String(characters[range]), token: token))
        }

        while index < characters.count {
            guard characters[index] == "<" else {
                plain.append(characters[index])
                index += 1
                continue
            }

            // Comments and declarations run to their own terminator.
            if index + 3 < characters.count, characters[index + 1] == "!" {
                var end = index
                while end < characters.count, characters[end] != ">" { end += 1 }
                end = min(characters.count, end + 1)
                emit(index..<end, .comment)
                index = end
                continue
            }

            var scan = index + 1
            if scan < characters.count, characters[scan] == "/" { scan += 1 }
            let nameStart = scan
            while scan < characters.count,
                  characters[scan].isLetter || characters[scan].isNumber
                      || characters[scan] == "-" || characters[scan] == ":" {
                scan += 1
            }
            // A bare `<` in prose — `a < b` — is not the start of anything.
            guard scan > nameStart else {
                plain.append(characters[index])
                index += 1
                continue
            }
            emit(index..<scan, .tag)
            index = scan

            // Inside the tag: names, `=`, quoted values, until it closes.
            while index < characters.count, characters[index] != ">" {
                let character = characters[index]
                if character == "\"" || character == "'" {
                    var end = index + 1
                    while end < characters.count, characters[end] != character { end += 1 }
                    end = min(characters.count, end + 1)
                    emit(index..<end, .string)
                    index = end
                    continue
                }
                if character.isLetter || character == "_" {
                    var end = index
                    while end < characters.count,
                          characters[end].isLetter || characters[end].isNumber
                              || characters[end] == "-" || characters[end] == "_"
                              || characters[end] == ":" {
                        end += 1
                    }
                    emit(index..<end, .property)
                    index = end
                    continue
                }
                plain.append(character)
                index += 1
            }
            if index < characters.count {
                emit(index..<(index + 1), .tag)
                index += 1
            }
        }

        flush()
        return runs
    }
}
