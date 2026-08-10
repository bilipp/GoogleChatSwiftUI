import AppKit
import SwiftUI

/// A fenced code block, on its own panel inside the bubble.
///
/// Code gets a panel rather than the wash inline code uses, because a block is a
/// thing you read line by line and act on, not a phrase inside a sentence: it needs
/// an edge to scan against, a label saying what language it is, and a way to take it
/// away with you.
///
/// The panel looks the same whoever sent the message. Highlighting is only legible on
/// the ground its colours were designed for, so the panel makes its own ground —
/// near-white in a light window, Xcode's `#1F1F24` in a dark one — instead of taking a
/// tint from the accent-filled own bubble it may be sitting in. Two grounds, two
/// palettes, and code that reads the same on both sides of the conversation.
struct CodeBlockView: View {
    /// Set only when the fence carried a tag we recognise. What the tab says.
    let language: CodeLanguage?
    let code: String

    @Environment(\.colorScheme) private var colorScheme

    /// Swapped for a checkmark after a copy. Nothing moves when it changes — the two
    /// glyphs occupy the same slot — so the transcript beneath does not reflow.
    @State private var didCopy = false

    private let corner: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            codeArea
        }
        .background(panel)
        .clipShape(.rect(cornerRadius: corner))
        .overlay {
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(edge, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.map { "\($0.displayName) code block" } ?? "Code block")
        .accessibilityValue(code)
    }

    // MARK: - Colours

    private var isDark: Bool { colorScheme == .dark }

    private var palette: CodeSyntaxPalette { isDark ? .dark : .light }

    /// The code, coloured — by the fence's tag when there was one, and by detection when
    /// there was not.
    ///
    /// A detected language never reaches the tab. Colouring by a guess costs little when
    /// the guess is wrong, but a label is a claim about what somebody else sent, and a
    /// detector working from three lines of a chat message has no business making one.
    private var highlighted: AttributedString {
        HighlightedCode.attributed(code, language: language, isDark: isDark)
    }

    // MARK: - Header

    /// A tab in the panel's top corner rather than a bar across it, and nothing in it
    /// stretches — no `Spacer`, no `Divider`.
    ///
    /// Either of those claims every point the bubble offers, and a two-word snippet
    /// then sits in a panel as wide as the transcript: the same trap the block layout
    /// in ``FormattedMessageText`` avoids. The panel ends where its widest line ends,
    /// and the tab is as wide as what it says.
    private var header: some View {
        HStack(spacing: 7) {
            Text(language?.displayName ?? "Code")
                .font(.caption2.weight(.semibold))
            copyButton
        }
        // The comment colour, so the chrome belongs to the same theme as the code and
        // stays quieter than any of it.
        .foregroundStyle(palette.comment)
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .padding(.bottom, 3)
        .background(
            tab,
            // Square where it meets the panel's own corner, rounded where it leaves
            // off, so it reads as a tab on the surface and not a box floating on it.
            in: .rect(topLeadingRadius: corner, bottomTrailingRadius: corner)
        )
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "square.on.square")
                .font(.caption2)
                // A fixed slot, so the panel does not resize by a point when the
                // narrower checkmark takes over.
                .frame(width: 11, height: 11)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Copy code")
        .accessibilityLabel(didCopy ? "Copied" : "Copy code")
    }

    // MARK: - Code

    /// Code that fits is laid out snug; code that does not wraps to the bubble's width.
    ///
    /// `ViewThatFits` measures the snug candidate at its ideal width — the width of its
    /// longest line, which is what `fixedSize` horizontally reports — and takes it when
    /// there is room. That is what keeps a two-line snippet's panel as short as the
    /// snippet instead of stretching it across the transcript.
    ///
    /// The fallback wraps rather than scrolls. A wrapped line does cost something a
    /// scroller does not: the break no longer means a statement ended. But nothing that
    /// has to be dragged sideways gets read, and a long line hidden past the panel's edge
    /// is a line nobody sees at all — so the whole line, folded, beats half a line with
    /// the rest behind a gesture. It claims the full width on offer, because a wrap that
    /// happens earlier than it must is a fold for no reason.
    private var codeArea: some View {
        ViewThatFits(in: .horizontal) {
            codeText(wrapping: false)
            codeText(wrapping: true)
        }
    }

    /// - Parameter wrapping: when false, `fixedSize` horizontally refuses the wrap and
    ///   makes the text report its longest line as its ideal width, which is what
    ///   `ViewThatFits` judges. When true the text takes the proposed width and folds
    ///   into it, and vertical `fixedSize` is what gets it the height every folded line
    ///   needs instead of one truncated one.
    private func codeText(wrapping: Bool) -> some View {
        Text(highlighted)
            .font(.system(.callout, design: .monospaced))
            .lineSpacing(2)
            .fixedSize(horizontal: !wrapping, vertical: true)
            .frame(maxWidth: wrapping ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
    }

    // MARK: - Material

    /// Lit from the top rather than filled flat, so the panel reads as a surface set
    /// into the bubble instead of a rectangle of tinted text background.
    private var panel: some ShapeStyle {
        LinearGradient(
            colors: isDark
                ? [Color(hex: 0x26262C), Color(hex: 0x1D1D22)]
                : [Color(hex: 0xFFFFFF), Color(hex: 0xF4F4F7)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var tab: Color {
        isDark ? Color(hex: 0x33333A) : Color(hex: 0xE9E9EE)
    }

    private var edge: Color {
        isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
    }
}

#Preview("Code blocks") {
    VStack(alignment: .leading, spacing: 12) {
        CodeBlockView(language: .swift, code: "let x = 1")
        CodeBlockView(language: nil, code: "brew install jq && jq --version")
        CodeBlockView(
            language: .swift,
            code: """
                // Highlighted from Xcode's own palette.
                func blocks(_ raw: String, mentionNames: [String] = []) -> [ChatBlock] {
                    raw.isEmpty ? [] : parse(raw, count: 3)
                }
                """
        )
        CodeBlockView(
            language: nil,
            code: "curl -sS -H \"Authorization: Bearer $TOKEN\" https://chat.googleapis.com/v1/spaces/AAAA/messages?pageSize=100 | jq '.messages[].text'"
        )
        CodeBlockView(language: .shell, code: "swift test --filter ChatText")
            .padding(10)
            .background(Color.accentColor.gradient, in: .rect(cornerRadius: 12))
    }
    .padding(16)
    .frame(width: 460)
}
