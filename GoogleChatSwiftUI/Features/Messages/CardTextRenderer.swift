import Foundation
import SwiftUI

/// Renders the HTML subset Chat allows inside card text.
///
/// Cards support `<b> <i> <u> <s>/<strike> <font color> <a href> <br>` and nothing
/// else. Parsed by hand rather than via `NSAttributedString`'s HTML importer: that
/// importer pulls in a full WebKit-backed parser, runs on the main thread, and would
/// happily interpret markup Chat never sends.
nonisolated enum CardTextRenderer {
    static func attributed(_ html: String) -> AttributedString {
        var styles = StyleStack()
        var output = AttributedString()
        var text = ""

        func flush() {
            guard !text.isEmpty else { return }
            output.append(styles.apply(to: AttributedString(decodeEntities(text))))
            text = ""
        }

        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            guard character == "<" else {
                text.append(character)
                index = html.index(after: index)
                continue
            }

            guard let close = html[index...].firstIndex(of: ">") else {
                // An unterminated '<' is literal text, not a broken tag.
                text.append(character)
                index = html.index(after: index)
                continue
            }

            let tag = String(html[html.index(after: index)..<close])
            flush()
            apply(tag: tag, to: &styles, output: &output)
            index = html.index(after: close)
        }
        flush()
        return output
    }

    // MARK: - Tags

    private static func apply(tag: String, to styles: inout StyleStack, output: inout AttributedString) {
        let lower = tag.lowercased().trimmingCharacters(in: .whitespaces)

        if lower == "br" || lower == "br/" || lower == "br /" {
            output.append(AttributedString("\n"))
            return
        }

        if lower.hasPrefix("/") {
            styles.pop(String(lower.dropFirst()))
            return
        }

        let name = lower.split(separator: " ").first.map(String.init) ?? lower
        switch name {
        case "b", "strong": styles.push(.bold, as: name)
        case "i", "em": styles.push(.italic, as: name)
        case "u": styles.push(.underline, as: name)
        case "s", "strike", "del": styles.push(.strikethrough, as: name)
        case "font":
            if let color = parseColor(from: tag) {
                styles.push(.color(color), as: name)
            } else {
                styles.push(.none, as: name)
            }
        case "a":
            if let url = parseAttribute("href", from: tag).flatMap(URL.init(string:)) {
                styles.push(.link(url), as: name)
            } else {
                styles.push(.none, as: name)
            }
        default:
            // Unknown tag: ignore the tag, keep the text. Dropping the content would
            // silently lose information a bot meant to convey.
            break
        }
    }

    private static func parseAttribute(_ name: String, from tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        var rest = tag[range.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else {
            return rest.prefix(while: { !$0.isWhitespace }).description
        }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    private static func parseColor(from tag: String) -> Color? {
        guard let raw = parseAttribute("color", from: tag) else { return nil }
        return Color(hex: raw) ?? namedColors[raw.lowercased()]
    }

    private static let namedColors: [String: Color] = [
        "red": .red, "green": .green, "blue": .blue, "yellow": .yellow,
        "orange": .orange, "purple": .purple, "gray": .gray, "grey": .gray,
        "black": .black, "white": .white, "cyan": .cyan, "teal": .teal,
    ]

    /// Only the entities Chat actually emits. A full table would be dead weight.
    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Style stack

    private enum Style {
        case bold, italic, underline, strikethrough
        case color(Color)
        case link(URL)
        /// A tag that opened but carries no usable styling; still needs a stack slot
        /// so its closing tag pops the right entry.
        case none
    }

    private struct StyleStack {
        private var entries: [(tag: String, style: Style)] = []

        mutating func push(_ style: Style, as tag: String) {
            entries.append((tag, style))
        }

        mutating func pop(_ tag: String) {
            // Search from the top: mismatched nesting is common in generated HTML,
            // and popping blindly would unwind styles that are still open.
            if let index = entries.lastIndex(where: { $0.tag == tag }) {
                entries.remove(at: index)
            }
        }

        func apply(to input: AttributedString) -> AttributedString {
            var result = input
            for entry in entries {
                switch entry.style {
                case .bold:
                    result.font = (result.font ?? .body).bold()
                case .italic:
                    result.font = (result.font ?? .body).italic()
                case .underline:
                    result.underlineStyle = .single
                case .strikethrough:
                    result.strikethroughStyle = .single
                case .color(let color):
                    result.foregroundColor = color
                case .link(let url):
                    result.link = url
                case .none:
                    break
                }
            }
            return result
        }
    }
}

nonisolated extension Color {
    /// Parses `#RGB`, `#RRGGBB`, and `#RRGGBBAA`.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()

        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16)
        else { return nil }

        let hasAlpha = value.count == 8
        let red = Double((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(number & 0xFF) / 255 : 1

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
