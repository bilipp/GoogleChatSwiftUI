import SwiftUI

/// Full emoji picker for reactions.
///
/// The catalogue is derived from Unicode scalar ranges filtered by
/// `isEmojiPresentation`, rather than a hand-typed literal: the property check keeps
/// unassigned and non-emoji code points out automatically, so the list stays correct
/// as Unicode grows instead of going stale.
struct EmojiPicker: View {
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var custom = ""
    @FocusState private var isCustomFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            customField

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                    ForEach(EmojiCatalogue.categories) { category in
                        let entries = filtered(category)
                        if !entries.isEmpty {
                            Section {
                                grid(entries)
                            } header: {
                                Text(category.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                                    .background(.background)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 300, height: 260)
        }
        .padding(10)
    }

    /// Ranges cannot express skin-tone modifiers, flags, or other ZWJ sequences, so
    /// arbitrary input stays available — the system palette (⌃⌘Space) types into here.
    private var customField: some View {
        HStack(spacing: 6) {
            TextField("Any emoji…", text: $custom)
                .textFieldStyle(.roundedBorder)
                .focused($isCustomFocused)
                .onSubmit(submitCustom)
            Button("Add", action: submitCustom)
                .disabled(firstEmoji(in: custom) == nil)
        }
        .controlSize(.small)
    }

    private func grid(_ entries: [String]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 8),
            spacing: 2
        ) {
            ForEach(entries, id: \.self) { emoji in
                Button {
                    onPick(emoji)
                } label: {
                    Text(emoji)
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React with \(emoji)")
            }
        }
    }

    private func filtered(_ category: EmojiCatalogue.Category) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return category.emoji }
        // Searching by character rather than by name: Unicode names are not exposed
        // by Foundation, and shipping a name database for this is not worth it.
        return category.emoji.filter { $0.contains(trimmed) }
    }

    private func submitCustom() {
        guard let emoji = firstEmoji(in: custom) else { return }
        custom = ""
        onPick(emoji)
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
