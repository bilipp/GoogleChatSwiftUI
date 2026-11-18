import SwiftUI

/// Full emoji picker for reactions.
///
/// The catalogue is derived from Unicode scalar ranges filtered by
/// `isEmojiPresentation`, rather than a hand-typed literal: the property check keeps
/// unassigned and non-emoji code points out automatically, so the list stays correct
/// as Unicode grows instead of going stale.
struct EmojiPicker: View {
    @Environment(ChatSessionModel.self) private var session

    let onPick: (String) -> Void

    @State private var text = ""
    /// Position in ``sections`` read as one list; Return reacts with what sits here.
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    /// Most a search shows: past this the words matched too loosely to be worth
    /// scrolling through.
    private static let resultLimit = 160
    private static let columns = 8

    /// One titled run of emoji, as drawn.
    private struct EmojiSection: Identifiable {
        let id: String
        let title: String
        let emoji: [String]
        /// Position of the section's first emoji in the whole list.
        let offset: Int
    }

    var body: some View {
        let sections = sections
        let flat = sections.flatMap(\.emoji)
        let current = flat.indices.contains(highlighted) ? flat[highlighted] : nil

        VStack(alignment: .leading, spacing: 8) {
            searchField(sections: sections, flat: flat)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                        if sections.isEmpty, let word = searchWord {
                            Text("No emoji match “\(word)”.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 24)
                        }
                        ForEach(sections) { section in
                            Section {
                                grid(section)
                            } header: {
                                sectionHeader(section.title)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(width: 300, height: 260)
                .onChange(of: highlighted) { _, new in
                    proxy.scrollTo(new)
                }
            }

            footer(current)
        }
        .padding(10)
        .onAppear { isFieldFocused = true }
        .onChange(of: text) { _, _ in highlighted = 0 }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .background(.background)
    }

    /// Searches by name, and still takes an emoji typed or pasted in: ranges cannot
    /// express skin-tone modifiers, flags, or other ZWJ sequences, so the system
    /// palette (⌃⌘Space) types into here.
    ///
    /// Focus never leaves the field. The arrows move the highlight through the grid
    /// from here, so typing, moving and Return all work without reaching for the mouse.
    private func searchField(sections: [EmojiSection], flat: [String]) -> some View {
        TextField("Search or paste an emoji", text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .focused($isFieldFocused)
            .onSubmit { submit(flat) }
            .onKeyPress(.leftArrow) { move(by: -1, count: flat.count) }
            .onKeyPress(.rightArrow) { move(by: 1, count: flat.count) }
            .onKeyPress(.upArrow) { moveRow(-1, in: sections) }
            .onKeyPress(.downArrow) { moveRow(1, in: sections) }
    }

    private func grid(_ section: EmojiSection) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: Self.columns),
            spacing: 2
        ) {
            ForEach(Array(section.emoji.enumerated()), id: \.offset) { index, emoji in
                let position = section.offset + index
                Button {
                    onPick(emoji)
                } label: {
                    ReactionEmoji(key: emoji)
                        .font(.title3)
                        .frame(width: 28, height: 28)
                        .background(
                            position == highlighted ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
                .buttonStyle(.plain)
                .id(position)
                .onHover { if $0 { highlighted = position } }
                .accessibilityLabel("React with \(label(for: emoji))")
            }
        }
    }

    /// The highlighted emoji, its name, and what Return will do with it.
    private func footer(_ emoji: String?) -> some View {
        HStack(spacing: 6) {
            if let emoji {
                ReactionEmoji(key: emoji)
                    .font(.title3)
                Text(label(for: emoji))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("↩ to react")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(" ").font(.title3)
            }
        }
        .frame(height: 22)
    }

    // MARK: - Contents

    /// What the grid shows: the search results, or with no search the organisation's
    /// emoji followed by the catalogue.
    private var sections: [EmojiSection] {
        var runs: [(String, String, [String])] = []
        if let results = searchResults {
            if !results.isEmpty { runs.append(("results", "Results", results)) }
        } else {
            let custom = session.customEmojis.compactMap { $0.uid.map(ChatEmoji.customKey(uid:)) }
            if !custom.isEmpty { runs.append(("custom", "Custom", custom)) }
            for category in EmojiCatalogue.categories {
                runs.append((category.id, category.name, category.emoji))
            }
        }
        var offset = 0
        return runs.map { id, title, emoji in
            defer { offset += emoji.count }
            return EmojiSection(id: id, title: title, emoji: emoji, offset: offset)
        }
    }

    private func label(for emoji: String) -> String {
        if ChatEmoji.customUID(fromKey: emoji) != nil {
            let name = session.emojiLabel(emoji).trimmingCharacters(in: .init(charactersIn: ":"))
            return ":\(name):"
        }
        return Self.shortcodes[emoji].map { ":\($0):" } ?? emoji
    }

    /// The name each emoji goes by in `:shortcode` completion, the first one listed
    /// where it has several.
    private static let shortcodes: [String: String] = Dictionary(
        EmojiShortcodeIndex.all.map { ($0.emoji, $0.shortcode) },
        uniquingKeysWith: { first, _ in first }
    )

    // MARK: - Keyboard

    private func move(by delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = min(max(highlighted + delta, 0), count - 1)
        return .handled
    }

    /// Up and down follow the columns as drawn. Sections start their own rows, so a
    /// short last row is a row of its own, and a column it lacks lands on its end.
    private func moveRow(_ delta: Int, in sections: [EmojiSection]) -> KeyPress.Result {
        var rows: [Range<Int>] = []
        for section in sections {
            var start = 0
            while start < section.emoji.count {
                let end = min(start + Self.columns, section.emoji.count)
                rows.append((section.offset + start)..<(section.offset + end))
                start = end
            }
        }
        guard let row = rows.firstIndex(where: { $0.contains(highlighted) }) else {
            return .ignored
        }
        let column = highlighted - rows[row].lowerBound
        let target = row + delta
        guard rows.indices.contains(target) else { return .handled }
        highlighted = min(rows[target].lowerBound + column, rows[target].upperBound - 1)
        return .handled
    }

    // MARK: - Search

    /// What is typed, read as a name: `:thumbs up:` and `thumbs_up` alike. Nil while
    /// the field is empty or holds an emoji itself.
    private var searchWord: String? {
        let word = text
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: .init(charactersIn: ":"))
            .lowercased()
        guard !word.isEmpty, firstEmoji(in: word) == nil else { return nil }
        return word
    }

    /// Emoji whose name fits the search, the organisation's own first, or nil when
    /// there is no search and the whole catalogue shows.
    ///
    /// Names come from the composer's `:shortcode` index, so a word finds here what it
    /// would complete there, ranked by the same recent-use history.
    private var searchResults: [String]? {
        guard let word = searchWord else { return nil }
        let shortcodeQuery = word.split(whereSeparator: \.isWhitespace).joined(separator: "_")

        let custom = session.customEmojis
            .filter { emoji in
                let name = (emoji.emojiName ?? "").trimmingCharacters(in: .init(charactersIn: ":"))
                return name.localizedCaseInsensitiveContains(word)
                    || name.localizedCaseInsensitiveContains(shortcodeQuery)
            }
            .compactMap { $0.uid.map(ChatEmoji.customKey(uid:)) }

        // One letter matches most of the catalogue, which the index declines to rank;
        // a prefix of the names is what someone typing one letter is reaching for.
        let unicode: [String]
        if shortcodeQuery.count < EmojiShortcodeIndex.minimumQueryLength {
            var seen = Set<String>()
            unicode = EmojiShortcodeIndex.all
                .filter { $0.shortcode.hasPrefix(shortcodeQuery) }
                .map(\.emoji)
                .filter { seen.insert($0).inserted }
                .prefix(Self.resultLimit)
                .map { $0 }
        } else {
            unicode = EmojiShortcodeIndex.matches(
                for: shortcodeQuery,
                recents: session.recentEmoji.recents,
                limit: Self.resultLimit
            ).map(\.emoji)
        }
        return custom + unicode
    }

    /// Return reacts with an emoji typed or pasted into the field, or else with the
    /// highlighted one — the best match while searching.
    private func submit(_ flat: [String]) {
        let picked = firstEmoji(in: text)
            ?? (flat.indices.contains(highlighted) ? flat[highlighted] : nil)
        guard let picked else { return }
        text = ""
        onPick(picked)
    }

    /// Takes the first grapheme cluster that actually is an emoji, so stray text
    /// pasted alongside it doesn't get sent to the API.
    private func firstEmoji(in text: String) -> String? {
        for character in text where character.unicodeScalars.contains(where: {
            $0.properties.isEmoji && ($0.value > 0x238C || character.unicodeScalars.count > 1)
        }) {
            return String(character)
        }
        return nil
    }
}

/// Emoji grouped into categories, built once at first use.
///
/// Nonisolated because ``EmojiShortcodeIndex`` derives the composer's `:shortcode`
/// table from it, and that is pure text work with no reason to be on the main actor.
nonisolated enum EmojiCatalogue {
    struct Category: Identifiable, Sendable {
        let id: String
        let name: String
        let emoji: [String]
    }

    static let categories: [Category] = build()

    private static func build() -> [Category] {
        let definitions: [(String, [ClosedRange<UInt32>])] = [
            ("Smileys", [0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A]),
            ("People", [0x1F464...0x1F487, 0x1F44A...0x1F450, 0x1F9B0...0x1F9DF]),
            ("Animals & Nature", [0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F343]),
            ("Food & Drink", [0x1F345...0x1F37F, 0x1F950...0x1F96F]),
            ("Activities", [0x1F380...0x1F3CA, 0x1F947...0x1F94F]),
            ("Travel & Places", [0x1F680...0x1F6C5, 0x1F30D...0x1F320]),
            ("Objects", [0x1F4A1...0x1F4FF, 0x1F526...0x1F53D]),
            ("Symbols", [0x1F493...0x1F4A0, 0x2795...0x2797, 0x1F500...0x1F525]),
        ]

        return definitions.map { name, ranges in
            var emoji: [String] = []
            for range in ranges {
                for value in range {
                    guard let scalar = Unicode.Scalar(value),
                          scalar.properties.isEmojiPresentation
                    else { continue }
                    emoji.append(String(scalar))
                }
            }
            return Category(id: name, name: name, emoji: emoji)
        }
    }
}
