import Foundation

/// A language a code block can be in.
///
/// Coarser than the tags people type: `js`, `jsx` and `javascript` are one case,
/// because the difference changes nothing about how the block is highlighted. Cases
/// exist where the lexing rules genuinely differ.
nonisolated enum CodeLanguage: String, Sendable, CaseIterable {
    case swift, objectiveC, cFamily, csharp, java, kotlin, javaScript, typeScript
    case python, ruby, go, rust, php, lua, scala
    case shell, sql, json, yaml, toml, css, markup, diff, graphQL, proto
    case makefile, dockerfile, http, markdown, text

    /// What the tab on the panel says.
    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .objectiveC: "Objective-C"
        case .cFamily: "C"
        case .csharp: "C#"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .javaScript: "JavaScript"
        case .typeScript: "TypeScript"
        case .python: "Python"
        case .ruby: "Ruby"
        case .go: "Go"
        case .rust: "Rust"
        case .php: "PHP"
        case .lua: "Lua"
        case .scala: "Scala"
        case .shell: "Shell"
        case .sql: "SQL"
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .css: "CSS"
        case .markup: "HTML"
        case .diff: "Diff"
        case .graphQL: "GraphQL"
        case .proto: "Protobuf"
        case .makefile: "Makefile"
        case .dockerfile: "Dockerfile"
        case .http: "HTTP"
        case .markdown: "Markdown"
        case .text: "Text"
        }
    }

    // MARK: - Fence tags

    /// The language for a tag written on the opening fence, or nil if the tag is not
    /// one we know.
    ///
    /// Deliberately an allowlist rather than a shape test — "any single word on the
    /// opening line" would swallow the first line of every fence that opens with one,
    /// and losing a line of someone's code is worse than leaving an unusual language
    /// unlabelled.
    init?(tag: String) {
        guard let language = CodeLanguage.byTag[tag.lowercased()] else { return nil }
        self = language
    }

    private static let byTag: [String: CodeLanguage] = [
        "bash": .shell, "c": .cFamily, "c++": .cFamily, "cc": .cFamily, "cpp": .cFamily,
        "console": .shell, "cs": .csharp, "csharp": .csharp, "css": .css,
        "diff": .diff, "dockerfile": .dockerfile, "go": .go, "golang": .go,
        "graphql": .graphQL, "groovy": .java, "h": .cFamily, "hpp": .cFamily,
        "html": .markup, "http": .http, "ini": .toml, "java": .java,
        "javascript": .javaScript, "js": .javaScript, "json": .json, "json5": .json,
        "jsonc": .json, "jsx": .javaScript, "kotlin": .kotlin, "kt": .kotlin,
        "lua": .lua, "m": .objectiveC, "makefile": .makefile, "markdown": .markdown,
        "md": .markdown, "mm": .objectiveC, "objc": .objectiveC,
        "objective-c": .objectiveC, "patch": .diff, "php": .php, "plaintext": .text,
        "proto": .proto, "protobuf": .proto, "py": .python, "python": .python,
        "rb": .ruby, "rs": .rust, "ruby": .ruby, "rust": .rust, "scala": .scala,
        "scss": .css, "sh": .shell, "shell": .shell, "sql": .sql, "svg": .markup,
        "swift": .swift, "text": .text, "toml": .toml, "ts": .typeScript,
        "tsx": .typeScript, "txt": .text, "typescript": .typeScript, "xml": .markup,
        "yaml": .yaml, "yml": .yaml, "zsh": .shell
    ]

    // MARK: - Detection

    /// Guesses the language of an untagged block, or nil when the guess would be a
    /// coin toss.
    ///
    /// Nil is a real answer and the common one for the two-line snippets a chat is
    /// full of: `x = 1` is six languages at once, and colouring it as any of them is
    /// worse than leaving it alone. Signals are weighted by how exclusive they are —
    /// `err != nil` says Go and nothing else, while a brace says almost nothing.
    ///
    /// The result colours the code but never labels it. A wrong colour is a wearable
    /// cost; a wrong label puts a claim about the language into someone else's message.
    static func detect(_ code: String) -> CodeLanguage? {
        // The head of a block is what says what it is, and every rule below is a
        // substring search: reading all of a 50 KB paste would cost proportionally more
        // to learn nothing extra.
        let body = code.count > 4_000 ? String(code.prefix(4_000)) : code
        let lines = body.components(separatedBy: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let upper = body.uppercased()
        let first = trimmed.first(where: { !$0.isEmpty }) ?? ""

        var scores: [CodeLanguage: Int] = [:]
        func score(_ language: CodeLanguage, _ points: Int) {
            scores[language, default: 0] += points
        }
        /// Points only if the marker is there, which keeps the rules below to one line each.
        func has(_ needle: String, _ language: CodeLanguage, _ points: Int) {
            if body.contains(needle) { score(language, points) }
        }
        func lineStarts(with prefix: String) -> Bool {
            trimmed.contains { $0.hasPrefix(prefix) }
        }

        // Whole-file giveaways first: a shebang or a document declaration settles the
        // question on its own.
        if first.hasPrefix("#!") {
            if first.contains("python") { score(.python, 10) }
            if first.contains("ruby") { score(.ruby, 10) }
            if first.contains("node") { score(.javaScript, 10) }
            if first.contains("sh") { score(.shell, 10) }
        }
        if first.hasPrefix("<?php") { score(.php, 12) }
        if upper.contains("<!DOCTYPE HTML") { score(.markup, 12) }

        // Diff, which is a format rather than a language and looks like nothing else.
        if lineStarts(with: "diff --git") { score(.diff, 8) }
        if trimmed.contains(where: { $0.hasPrefix("@@") && $0.hasSuffix("@@") }) { score(.diff, 6) }
        if lineStarts(with: "+++ ") && lineStarts(with: "--- ") { score(.diff, 5) }
        let changed = trimmed.count {
            ($0.hasPrefix("+") && !$0.hasPrefix("++")) || ($0.hasPrefix("-") && !$0.hasPrefix("--"))
        }
        if changed >= 2 { score(.diff, 3) }

        // Structured data.
        if (first.hasPrefix("{") || first.hasPrefix("[")), body.contains("\":") || body.contains("\": ") {
            score(.json, 7)
        }
        if first.hasPrefix("<"), body.contains("</") || body.contains("/>") { score(.markup, 6) }
        if lineStarts(with: "---") && body.contains(": ") { score(.yaml, 4) }
        if trimmed.contains(where: { $0.hasPrefix("- ") }), body.contains(": "), !body.contains(";") {
            score(.yaml, 3)
        }
        if trimmed.contains(where: { $0.hasPrefix("[") && $0.hasSuffix("]") }), body.contains(" = ") {
            score(.toml, 5)
        }

        // SQL is case-insensitive in practice, so match on the uppercased copy.
        if upper.contains("SELECT ") && upper.contains(" FROM ") { score(.sql, 8) }
        for clause in ["INSERT INTO", "CREATE TABLE", "ALTER TABLE", "DELETE FROM"] {
            if upper.contains(clause) { score(.sql, 8) }
        }
        if upper.contains("UPDATE ") && upper.contains(" SET ") { score(.sql, 7) }

        // Shell: the commonest thing anyone pastes into a chat, and usually one line
        // with no syntax in it at all — so the command name has to carry the guess.
        if lineStarts(with: "$ ") || lineStarts(with: "% ") { score(.shell, 6) }
        let commands: Set<String> = [
            "apt", "apt-get", "brew", "cat", "cd", "chmod", "cp", "curl", "defaults",
            "docker", "echo", "export", "gh", "git", "grep", "kill", "kubectl", "ls",
            "make", "mkdir", "mv", "npm", "npx", "open", "pip", "pip3", "pnpm", "pod",
            "rm", "scp", "sed", "ssh", "sudo", "swift", "tail", "tar", "unzip", "wget",
            "which", "xcodebuild", "xcrun", "yarn"
        ]
        for line in trimmed where !line.isEmpty {
            let word = line.drop { $0 == "$" || $0 == "%" || $0 == " " }
                .prefix { !$0.isWhitespace }
            if commands.contains(String(word)) { score(.shell, 5) }
        }
        if lineStarts(with: "#!/") { score(.shell, 2) }

        // Dockerfile and Makefile, both recognised by line shape.
        let dockerVerbs: Set<String> = [
            "FROM", "RUN", "COPY", "ADD", "WORKDIR", "CMD", "ENTRYPOINT", "ENV",
            "EXPOSE", "LABEL", "USER", "VOLUME", "ARG"
        ]
        if trimmed.count(where: { dockerVerbs.contains(String($0.prefix { !$0.isWhitespace })) }) >= 2 {
            score(.dockerfile, 7)
        }
        if zip(lines, lines.dropFirst()).contains(where: {
            $0.0.hasSuffix(":") && !$0.0.hasPrefix("\t") && $0.1.hasPrefix("\t")
        }) {
            score(.makefile, 4)
        }

        // Programming languages, in rough order of how exclusive their markers are.
        has("err != nil", .go, 8); has(":=", .go, 5); has("fmt.", .go, 5)
        has("package main", .go, 6); has("func (", .go, 2)

        has("fn ", .rust, 5); has("let mut ", .rust, 7); has("println!", .rust, 8)
        has(".unwrap()", .rust, 6); has("impl ", .rust, 4); has("&str", .rust, 5)
        has("Vec<", .rust, 4)

        has("func ", .swift, 4); has("guard ", .swift, 5); has("import SwiftUI", .swift, 9)
        has("import Foundation", .swift, 8); has("some View", .swift, 8)
        has("-> ", .swift, 1); has("@State", .swift, 7); has("if let ", .swift, 5)
        has("?? ", .swift, 3); has("struct ", .swift, 2); has("[weak self]", .swift, 7)

        has("@interface", .objectiveC, 10); has("@implementation", .objectiveC, 10)
        has("NSLog(", .objectiveC, 7); has("nonatomic", .objectiveC, 7)

        has("def ", .python, 5); has("elif ", .python, 7); has("None", .python, 4)
        has("self.", .python, 2); has("__init__", .python, 8)
        if lineStarts(with: "from ") && body.contains(" import ") { score(.python, 7) }
        if lineStarts(with: "import "), !body.contains(";"), !body.contains("{") { score(.python, 1) }
        if body.contains("{") && body.contains(";") { score(.python, -4) }

        has("puts ", .ruby, 7); has("do |", .ruby, 7); has("nil?", .ruby, 6)
        has("=> ", .ruby, 2); has("attr_accessor", .ruby, 8)
        if body.contains("def ") && trimmed.contains("end") { score(.ruby, 5) }

        has("=>", .javaScript, 3); has("console.log", .javaScript, 8)
        has("const ", .javaScript, 4); has("function ", .javaScript, 4)
        has("===", .javaScript, 5); has("require(", .javaScript, 4)
        has("export default", .javaScript, 5); has("async function", .javaScript, 4)
        has("useState", .javaScript, 5); has("null", .javaScript, 1)

        has("interface ", .typeScript, 5); has(": string", .typeScript, 6)
        has(": number", .typeScript, 6); has(": boolean", .typeScript, 6)
        has("as const", .typeScript, 6); has("readonly ", .typeScript, 4)

        has("public static void main", .java, 12); has("System.out", .java, 8)
        has("public class ", .java, 5); has("@Override", .java, 6)

        has("fun ", .kotlin, 6); has("val ", .kotlin, 4); has("println(", .kotlin, 2)
        has("companion object", .kotlin, 8)

        has("using System", .csharp, 9); has("Console.WriteLine", .csharp, 9)
        has("namespace ", .csharp, 4)

        has("local ", .lua, 5); has("elseif ", .lua, 6)
        has("$this->", .php, 8); has("echo ", .php, 3)

        has("query {", .graphQL, 6); has("mutation ", .graphQL, 6)
        has("syntax = \"proto", .proto, 12); has("message ", .proto, 2)

        if lineStarts(with: "#include") { score(.cFamily, 8) }
        has("int main(", .cFamily, 6); has("printf(", .cFamily, 5)
        has("std::", .cFamily, 8); has("NULL", .cFamily, 3)

        // CSS: a selector line that opens a brace, over declarations that end in a
        // semicolon. Distinctive enough not to need much else.
        if trimmed.contains(where: { $0.hasSuffix("{") && ($0.hasPrefix(".") || $0.hasPrefix("#") || $0.hasPrefix("@")) }),
           trimmed.contains(where: { $0.contains(":") && $0.hasSuffix(";") }) {
            score(.css, 8)
        }

        if ["GET ", "POST ", "PUT ", "DELETE ", "PATCH "].contains(where: { first.hasPrefix($0) }),
           body.contains("HTTP/") || first.contains("/") {
            score(.http, 6)
        }

        // A guess needs to be worth making. Below this, colouring is noise dressed up
        // as information.
        guard let best = scores.filter({ $0.value >= 5 }).max(by: { left, right in
            // Ties resolve by the case order, so the same input always lands the same
            // way rather than following dictionary iteration.
            left.value == right.value
                ? left.key.orderIndex > right.key.orderIndex
                : left.value < right.value
        }) else {
            return nil
        }
        return best.key
    }

    private var orderIndex: Int {
        CodeLanguage.allCases.firstIndex(of: self) ?? 0
    }
}
