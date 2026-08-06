import Foundation
import SwiftUI

/// Turns Chat's plain-text-with-markup into styled text.
///
/// Chat sends `*bold*`, `_italic_`, `~strike~`, `` `code` `` and ```` ```block``` ````
/// literally in `text`, so rendering it raw shows the asterisks. Mentions arrive as
/// separate annotations rather than inline markup.
nonisolated enum ChatTextRenderer {
    /// - Parameter mentionNames: display names of users mentioned in this message,
    ///   used to highlight the matching `@Name` spans.
    static func attributed(
        _ raw: String,
        mentionNames: [String] = [],
        isOwn: Bool = false
    ) -> AttributedString {
        var result = applyInlineMarkup(to: raw)
        linkifyURLs(in: &result, isOwn: isOwn)
        highlightMentions(in: &result, names: mentionNames, isOwn: isOwn)
        return result
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
                  let upper = AttributedString.Index(stringRange.upperBound, within: text)
            else { continue }

            text[lower..<upper].link = url
            text[lower..<upper].underlineStyle = .single
            // Accent-on-accent would vanish inside an own-message bubble.
            text[lower..<upper].foregroundColor = isOwn ? .white : .accentColor
        }
    }

    // MARK: - Markup

    private struct Rule: Sendable {
        let delimiter: Character
        /// `@Sendable` so the rule table can be a static constant under strict
        /// concurrency — closures are not Sendable by default.
        let apply: @Sendable (inout AttributedString) -> Void
    }

    private static let rules: [Rule] = [
        Rule(delimiter: "*") { $0.font = $0.font?.bold() ?? .body.bold() },
        Rule(delimiter: "_") { $0.font = $0.font?.italic() ?? .body.italic() },
        Rule(delimiter: "~") { $0.strikethroughStyle = .single },
        Rule(delimiter: "`") { run in
            run.font = .system(.body, design: .monospaced)
        },
    ]

    private static func applyInlineMarkup(to raw: String) -> AttributedString {
        var text = raw
        var spans: [(range: Range<String.Index>, rule: Rule)] = []

        // Strip delimiters one style at a time, recording where the styling applied.
        for rule in rules {
            (text, spans) = extract(rule: rule, from: text, existing: spans)
        }

        var attributed = AttributedString(text)
        for span in spans {
            guard let lower = AttributedString.Index(span.range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(span.range.upperBound, within: attributed)
            else { continue }
            var slice = AttributedString(attributed[lower..<upper])
            span.rule.apply(&slice)
            attributed.replaceSubrange(lower..<upper, with: slice)
        }
        return attributed
    }

    /// Removes `delimiter…delimiter` pairs, returning the cleaned text plus the
    /// ranges that should be styled. Existing spans are dropped because their
    /// indices no longer hold once characters are removed — each pass restyles from
    /// the current string, which keeps the index maths honest at the cost of only
    /// supporting one style per span.
    private static func extract(
        rule: Rule,
        from source: String,
        existing: [(range: Range<String.Index>, rule: Rule)]
    ) -> (String, [(range: Range<String.Index>, rule: Rule)]) {
        var output = ""
        var spans: [(range: Range<String.Index>, rule: Rule)] = []
        var pendingStart: String.Index?

        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == rule.delimiter {
                if let start = pendingStart {
                    // Closing delimiter: the span covers everything written since.
                    spans.append((start..<output.endIndex, rule))
                    pendingStart = nil
                } else {
                    pendingStart = output.endIndex
                }
            } else {
                output.append(character)
            }
            index = source.index(after: index)
        }

        // An unmatched delimiter is literal text, not markup — put it back.
        if pendingStart != nil {
            return (source, existing)
        }

        // Re-anchor previously found spans by offset, since indices shifted.
        var carried: [(range: Range<String.Index>, rule: Rule)] = []
        for span in existing {
            let lowerOffset = source.distance(from: source.startIndex, to: span.range.lowerBound)
            let upperOffset = source.distance(from: source.startIndex, to: span.range.upperBound)
            guard lowerOffset <= output.count, upperOffset <= output.count else { continue }
            let lower = output.index(output.startIndex, offsetBy: lowerOffset)
            let upper = output.index(output.startIndex, offsetBy: upperOffset)
            carried.append((lower..<upper, span.rule))
        }

        return (output, carried + spans)
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
                guard !candidate.isEmpty, let range = text.range(of: candidate) else { continue }
                text[range].font = (text[range].font ?? .body).weight(.semibold)
                // Accent-on-accent would be invisible inside an own-message bubble.
                text[range].foregroundColor = isOwn ? .white : .accentColor
                break
            }
        }
    }
}
