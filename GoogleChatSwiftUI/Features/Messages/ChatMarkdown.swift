import Foundation

/// Rewrites Chat's own markup as the Markdown this app now sends.
///
/// A message comes back as `formattedText` in Chat's dialect — `*bold*`, `~strike~`,
/// `<https://x|label>`, `<users/123>` — whatever syntax it was written in. Editing one
/// and posting the text back as Markdown would turn its bold into italics and its
/// links into literal angle brackets, so the edit field is filled with this instead.
///
/// Only what differs between the two is touched. `_italic_` and backtick code mean the
/// same in both, and code is copied verbatim so a `*` inside it stays a `*`. Text that
/// is already Markdown passes through unchanged: `**` and `~~` are never single
/// markers, which is what makes running this twice harmless.
nonisolated enum ChatMarkdown {
    /// Rewrites Markdown mention elements as Chat's own `<users/123>` token.
    ///
    /// A message posted as Markdown comes back with its mentions still written as
    /// elements — `<chat-user data-user="users/123"></chat-user>` — in `formattedText`,
    /// rather than the `<users/123>` every other message carries. Folding the one into
    /// the other here means the renderer, the name lookup and the edit field each keep
    /// a single mention form to understand.
    static func normalizingMentions(_ text: String) -> String {
        guard text.contains("<chat-user") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return mentionElement.stringByReplacingMatches(
            in: text, range: range, withTemplate: "<$1>"
        )
    }

    /// An opening tag naming a user, self-closed or followed by whatever Chat put
    /// inside it and a closing tag — or by neither, as this app sends it.
    private static let mentionElement = try! NSRegularExpression(
        pattern: #"<chat-user\s+data-user\s*=\s*["'](users/[^"'\s]+)["'][^>]*?/?>(?:[^<]*</chat-user\s*>)?"#,
        options: [.caseInsensitive]
    )

    static func fromChatSyntax(_ text: String) -> String {
        convert(Array(text))
    }

    private static func convert(_ chars: [Character]) -> String {
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]

            if c == "`" {
                let run = runLength(of: "`", in: chars, at: i)
                if let close = closingRun(of: "`", length: run, in: chars, from: i + run) {
                    out += String(chars[i..<(close + run)])
                    i = close + run
                } else {
                    out += String(repeating: "`", count: run)
                    i += run
                }
                continue
            }

            if c == "*" || c == "~", isLone(c, in: chars, at: i),
               let close = closingMarker(c, in: chars, from: i) {
                let marker = String([c, c])
                out += marker + convert(Array(chars[(i + 1)..<close])) + marker
                i = close + 1
                continue
            }

            if c == "<", let close = chars[(i + 1)...].firstIndex(of: ">"),
               let rewritten = rewriteAngle(String(chars[(i + 1)..<close])) {
                out += rewritten
                i = close + 1
                continue
            }

            out.append(c)
            i += 1
        }
        return out
    }

    /// `<users/…>` becomes a Markdown mention and `<url|label>` a Markdown link. Other
    /// angle text — a bare `<https://…>`, a `<chat-user …>` already in Markdown, or
    /// someone writing `a <b> c` — is left as it is.
    private static func rewriteAngle(_ inner: String) -> String? {
        if inner.hasPrefix("users/"), !inner.contains(where: \.isWhitespace) {
            return MentionEncoder.markup(for: inner)
        }
        guard let bar = inner.firstIndex(of: "|") else { return nil }
        let url = String(inner[..<bar])
        let label = String(inner[inner.index(after: bar)...])
        guard url.contains(":"), !url.contains(where: \.isWhitespace), !label.isEmpty
        else { return nil }
        return "[\(label)](\(url))"
    }

    /// A single `*` or `~`, not one half of `**` or `~~`.
    private static func isLone(_ c: Character, in chars: [Character], at i: Int) -> Bool {
        (i == 0 || chars[i - 1] != c) && (i + 1 == chars.count || chars[i + 1] != c)
    }

    /// The marker closing the span opened at `open`, on the same line.
    ///
    /// Chat only formats a span that hugs its text — `*a*`, never `* a *` — so both
    /// ends have to touch a non-space character. Without that, `2 * 3 * 4` would come
    /// out bold.
    private static func closingMarker(_ c: Character, in chars: [Character], from open: Int) -> Int? {
        guard open + 1 < chars.count, !chars[open + 1].isWhitespace else { return nil }
        var j = open + 2
        while j < chars.count, !chars[j].isNewline {
            if chars[j] == c, isLone(c, in: chars, at: j), !chars[j - 1].isWhitespace {
                return j
            }
            j += 1
        }
        return nil
    }

    private static func runLength(of c: Character, in chars: [Character], at i: Int) -> Int {
        var n = 0
        while i + n < chars.count, chars[i + n] == c { n += 1 }
        return n
    }

    /// The start of the next run of exactly `length` copies of `c`.
    private static func closingRun(of c: Character, length: Int, in chars: [Character], from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            let run = runLength(of: c, in: chars, at: j)
            if run == length { return j }
            j += max(run, 1)
        }
        return nil
    }
}
