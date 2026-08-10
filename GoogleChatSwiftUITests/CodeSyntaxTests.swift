import Foundation
import Testing

@testable import GoogleChatSwiftUI

/// Highlighting has two halves that can each be wrong on their own: deciding what
/// language a block is in, and colouring it. The rules that matter are the ones that
/// keep a malformed snippet — which is most of what a chat carries — from bleeding one
/// colour across the rest of the block.
struct CodeSyntaxTests {
    // MARK: - Helpers

    private func runs(_ code: String, _ language: CodeLanguage) -> [CodeRun] {
        CodeSyntax.runs(code, language: language)
    }

    /// The kind assigned to an exact run. Nil when no run covers precisely that text,
    /// which is itself a failure worth reporting.
    private func token(_ text: String, in runs: [CodeRun]) -> CodeToken? {
        runs.first { $0.text == text }?.token
    }

    // MARK: - The invariant everything else rests on

    /// Runs are how the code is rebuilt as styled text, so anything the lexer drops or
    /// duplicates is a visible corruption of somebody's message. Checked across every
    /// lexer — the general one, and the two line-based special cases.
    @Test(arguments: [
        (CodeLanguage.swift, "guard let x else { return nil } // done\nlet s = \"hi\\\"there\""),
        (.python, "@cache\ndef f(a=3):\n    return '''x'''  # note"),
        (.json, "{\n  \"a\": [1, 2.5, true, null],\n  \"b\": \"c\"\n}"),
        (.shell, "brew install jq && echo \"$HOME/bin\" | tee -a ~/.zshrc # go"),
        (.diff, "@@ -1,2 +1,2 @@\n-old\n+new\n context"),
        (.markup, "<a href=\"x\">text</a><!-- c -->\n<br/>"),
        (.sql, "SELECT * FROM t WHERE a = 'b' -- why"),
        (.yaml, "# c\nname: value\nlist:\n  - one\n  - two"),
        (.rust, "let mut v: Vec<&str> = vec![]; // 'a is not a string"),
        (.text, "anything at all")
    ])
    func runsReproduceTheInputExactly(language: CodeLanguage, code: String) {
        let rebuilt = runs(code, language).map(\.text).joined()
        #expect(rebuilt == code)
    }

    // MARK: - Lexing

    @Test func swiftKeywordsTypesStringsAndCommentsAreTold_apart() {
        let lexed = runs("let name: String = \"hi\" // greeting", .swift)

        #expect(token("let", in: lexed) == .keyword)
        #expect(token("String", in: lexed) == .type)
        #expect(token("\"hi\"", in: lexed) == .string)
        #expect(token("// greeting", in: lexed) == .comment)
    }

    @Test func swiftAttributesAreTheirOwnKind() {
        let lexed = runs("@State private var count = 0", .swift)

        #expect(token("@State", in: lexed) == .attribute)
        #expect(token("private", in: lexed) == .keyword)
        #expect(token("0", in: lexed) == .number)
    }

    /// A name being called reads differently from a name being passed, and it is the
    /// one distinction a lexer can make without a symbol table.
    @Test func aNameFollowedByAParenthesisIsAFunction() {
        let lexed = runs("parse(raw)", .swift)

        #expect(token("parse", in: lexed) == .function)
        #expect(token("raw", in: lexed) == nil)
    }

    /// JSON's whole structure is keys against values, so a quoted string before a colon
    /// is not the same thing as a quoted string after one.
    @Test func jsonKeysAreDistinctFromJsonStrings() {
        let lexed = runs("{\"space\": \"spaces/AAQA\"}", .json)

        #expect(token("\"space\"", in: lexed) == .property)
        #expect(token("\"spaces/AAQA\"", in: lexed) == .string)
    }

    @Test func yamlKeysAreReadAtTheHeadOfTheLineOnly() {
        let lexed = runs("name: a value\n  - item: two", .yaml)

        #expect(token("name", in: lexed) == .property)
        #expect(token("item", in: lexed) == .property)
        // A bare word in the value is just a word.
        #expect(token("value", in: lexed) == nil)
    }

    /// The commonest thing anyone pastes is one shell command, where the only thing
    /// worth colouring is which word is the program.
    @Test func theFirstWordOfAShellLineIsTheCommand() {
        let lexed = runs("brew install jq\ngit push", .shell)

        #expect(token("brew", in: lexed) == .function)
        #expect(token("install", in: lexed) == nil)
        #expect(token("git", in: lexed) == .function)
    }

    @Test func shellVariablesAreCalledOut() {
        let lexed = runs("echo $HOME ${PATH}", .shell)

        #expect(token("$HOME", in: lexed) == .property)
        #expect(token("${PATH}", in: lexed) == .property)
    }

    @Test func sqlKeywordsMatchWhateverCaseTheyWereTypedIn() {
        let lexed = runs("select * From t", .sql)

        #expect(token("select", in: lexed) == .keyword)
        #expect(token("From", in: lexed) == .keyword)
    }

    @Test func diffMarksWholeLinesByTheirFirstCharacter() {
        let lexed = runs("@@ -1 +1 @@\n-gone\n+added\n same", .diff)

        #expect(token("@@ -1 +1 @@", in: lexed) == .property)
        #expect(token("-gone", in: lexed) == .removed)
        #expect(token("+added", in: lexed) == .added)
        #expect(token(" same", in: lexed) == .plain)
    }

    @Test func markupSeparatesTagsFromAttributesAndValues() {
        let lexed = runs("<div class=\"row\">hi</div>", .markup)

        #expect(token("<div", in: lexed) == .tag)
        #expect(token("class", in: lexed) == .property)
        #expect(token("\"row\"", in: lexed) == .string)
        #expect(token("</div", in: lexed) == .tag)
    }

    /// Chat snippets are cut mid-line constantly. An unclosed quote has to stop at the
    /// line break instead of painting everything after it as string.
    @Test func anUnterminatedStringStopsAtTheEndOfItsLine() {
        let lexed = runs("print(\"oops\nlet x = 1", .swift)

        #expect(token("let", in: lexed) == .keyword)
    }

    /// A Rust lifetime is not an opening quote, and treating it as one turns the rest
    /// of the line into a string.
    @Test func aRustLifetimeIsNotAString() {
        let lexed = runs("fn f<'a>(s: &'a str) -> bool { true }", .rust)

        #expect(token("bool", in: lexed) == nil)
        #expect(token("true", in: lexed) == .keyword)
        #expect(runs("fn f<'a>(s: &'a str) -> bool { true }", .rust)
            .contains { $0.token == .string } == false)
    }

    // MARK: - Detection

    @Test(arguments: [
        ("{\n  \"space\": \"spaces/AAQA\",\n  \"text\": \"hi\"\n}", CodeLanguage.json),
        ("@@ -1,3 +1,3 @@\n-was\n+now", .diff),
        ("brew install jq", .shell),
        ("$ xcodebuild test -scheme App", .shell),
        ("guard let space else { return }\nlet name = space.name", .swift),
        ("import SwiftUI\n\nstruct V: View {}", .swift),
        ("def parse(raw):\n    if raw is None:\n        return []", .python),
        ("if err != nil {\n\treturn err\n}", .go),
        ("let mut total = 0;\nprintln!(\"{}\", total);", .rust),
        ("SELECT id, name FROM users WHERE id = 3", .sql),
        ("const x = items.map(i => i.id)\nconsole.log(x)", .javaScript),
        ("<html>\n<body><p>hi</p></body>\n</html>", .markup),
        ("FROM swift:6\nRUN swift build\nCMD [\"app\"]", .dockerfile)
    ])
    func detectionRecognisesWhatItShould(code: String, expected: CodeLanguage) {
        #expect(CodeLanguage.detect(code) == expected)
    }

    /// Nil is the honest answer far more often than a guess is, and it is the answer
    /// that leaves the block alone. Two lines of arithmetic are not any language in
    /// particular.
    @Test(arguments: [
        "x = 1",
        "hello",
        "a + b\nc + d",
        "TODO: ask Ada about this",
        "1\n2\n3"
    ])
    func detectionDeclinesWhenTheCodeSaysNothing(code: String) {
        #expect(CodeLanguage.detect(code) == nil)
    }

    // MARK: - The view's way in

    /// The cache is what the view actually calls, so the wiring through it has to be
    /// covered too: an untagged block gets detected on the way past, and a repeat call
    /// answers the same thing it did the first time.
    @MainActor
    @Test func theCacheDetectsUntaggedCodeAndAnswersConsistently() throws {
        let code = "guard let space else { return }"

        let first = HighlightedCode.attributed(code, language: nil, isDark: false)
        let again = HighlightedCode.attributed(code, language: nil, isDark: false)

        #expect(String(first.characters) == code)
        #expect(first == again)

        // Detection found Swift, so `guard` is not the same colour as the rest.
        let keyword = try #require(first.range(of: "guard"))
        let plain = try #require(first.range(of: "space"))
        #expect(first[keyword].runs.first?.foregroundColor != first[plain].runs.first?.foregroundColor)

        // And the theme is part of what is remembered, not something the first caller
        // fixes for everyone.
        let dark = HighlightedCode.attributed(code, language: nil, isDark: true)
        #expect(dark[keyword].runs.first?.foregroundColor
            != first[keyword].runs.first?.foregroundColor)
    }

    /// Every tag we accept has to lex, or a fence tagged with it lands in a `default`
    /// branch that was never tried.
    @Test func everyLanguageLexesWithoutLosingCharacters() {
        let sample = "a b(c) \"d\" 1 #x @y {e: 'f'} // g\n- h\n+ i"
        for language in CodeLanguage.allCases {
            let rebuilt = CodeSyntax.runs(sample, language: language).map(\.text).joined()
            #expect(rebuilt == sample, "\(language) lost or duplicated characters")
        }
    }
}
