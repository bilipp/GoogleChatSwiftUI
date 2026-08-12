import Foundation
import Testing

@testable import GoogleChatSwiftUI

/// The composer's `:shortcode` completion has two halves that can each be wrong
/// quietly: what counts as a shortcode being typed, and which emoji a fragment should
/// offer. The index is derived from ICU names rather than a fixed table, so these also
/// stand as the check that the derivation still produces the names people type.
struct EmojiShortcodeTests {
    // MARK: - Recognising a fragment

    @Test func findsFragmentAtEndOfText() throws {
        let text = "nearly done :smi"
        let match = try #require(EmojiShortcodeTrigger.pending(in: text))
        #expect(match.query == "smi")
        #expect(String(text[match.range]) == ":smi")
    }

    @Test func findsFragmentAtStartOfText() throws {
        let match = try #require(EmojiShortcodeTrigger.pending(in: ":rock"))
        #expect(match.query == "rock")
    }

    @Test func ignoresFragmentsShorterThanTheMinimum() {
        #expect(EmojiShortcodeTrigger.pending(in: "hello :s") == nil)
        #expect(EmojiShortcodeTrigger.pending(in: "hello :") == nil)
    }

    /// A colon glued to the preceding word is punctuation, a time, or a URL scheme.
    @Test(arguments: ["meet at 12:30", "https://example.com", "note:todo", "ratio 3:41"])
    func ignoresColonsThatFollowAWord(_ text: String) {
        #expect(EmojiShortcodeTrigger.pending(in: text) == nil)
    }

    /// The fragment has to be what is being typed right now.
    @Test func ignoresFragmentsThatAreNoLongerAtTheCaret() {
        #expect(EmojiShortcodeTrigger.pending(in: "hello :smile ") == nil)
        #expect(EmojiShortcodeTrigger.pending(in: "hello :smile\n") == nil)
    }

    @Test func ignoresRunsTooLongToBeAShortcode() {
        let long = String(repeating: "a", count: EmojiShortcodeIndex.maximumQueryLength + 1)
        #expect(EmojiShortcodeTrigger.pending(in: ":\(long)") == nil)
    }

    // MARK: - Closing colon

    @Test func substitutesAFullyTypedShortcode() throws {
        let text = "shipping it :tada:"
        let completed = try #require(EmojiShortcodeTrigger.completed(in: text))
        #expect(completed.emoji == "🎉")
        #expect(String(text[completed.range]) == ":tada:")
    }

    /// One-character shortcodes are too short to suggest, but explicit enough to close.
    @Test func substitutesSingleCharacterShortcodes() throws {
        let completed = try #require(EmojiShortcodeTrigger.completed(in: "nope :x:"))
        #expect(completed.emoji == "❌")
    }

    @Test func leavesUnknownShortcodesAlone() {
        #expect(EmojiShortcodeTrigger.completed(in: "see :notanemoji:") == nil)
        #expect(EmojiShortcodeTrigger.completed(in: "ratio 3:4:") == nil)
    }

    /// Otherwise every colon typed mid-sentence would flicker a substitution attempt.
    @Test func doesNotTreatAnOpeningColonAsClosed() {
        #expect(EmojiShortcodeTrigger.completed(in: "hello :") == nil)
    }

    // MARK: - Suggestions

    @Test func rankstheExactShortcodeFirst() throws {
        let matches = EmojiShortcodeIndex.matches(for: "smile")
        #expect(matches.first?.emoji == "😄")
    }

    /// Unicode names read as descriptions, so the word people remember is often last.
    @Test func matchesOnAnyWordOfTheName() {
        let matches = EmojiShortcodeIndex.matches(for: "joy")
        #expect(matches.contains { $0.emoji == "😂" })
    }

    @Test(arguments: ["thumbsup", "thumbs_up", "+1"])
    func reachesThumbsUpHoweverItIsSpelled(_ query: String) {
        #expect(EmojiShortcodeIndex.matches(for: query).first?.emoji == "👍")
    }

    /// An emoji reachable under both an alias and its Unicode name must not show twice.
    @Test func collapsesRepeatedEmoji() {
        for query in ["fire", "rocket", "smile", "heart"] {
            let emoji = EmojiShortcodeIndex.matches(for: query).map(\.emoji)
            #expect(Set(emoji).count == emoji.count, "\(query) suggested a duplicate")
        }
    }

    @Test func honoursTheSuggestionLimit() {
        #expect(EmojiShortcodeIndex.matches(for: "fa", limit: 3).count == 3)
        #expect(EmojiShortcodeIndex.matches(for: "fa").count <= EmojiShortcodeIndex.suggestionLimit)
    }

    @Test func offersNothingForFragmentsBelowTheMinimum() {
        #expect(EmojiShortcodeIndex.matches(for: "s").isEmpty)
    }

    @Test func offersNothingForNonsense() {
        #expect(EmojiShortcodeIndex.matches(for: "qqzzxx").isEmpty)
    }

    // MARK: - Recency

    /// The case this exists for: `:sli` fits 🙂 and 🍕 equally well, and the one the
    /// user keeps reaching for should be the one they can accept without reading.
    @Test func ordersEquallyGoodMatchesByRecentUse() {
        #expect(EmojiShortcodeIndex.matches(for: "sli").contains { $0.emoji == "🙂" })
        #expect(EmojiShortcodeIndex.matches(for: "sli", recents: ["🙂"]).first?.emoji == "🙂")
    }

    /// History is ordered, so the newer of two remembered emoji leads.
    @Test func prefersTheMoreRecentlyUsedEmoji() {
        #expect(EmojiShortcodeIndex.matches(for: "sli", recents: ["🍕", "🙂"]).first?.emoji == "🍕")
        #expect(EmojiShortcodeIndex.matches(for: "sli", recents: ["🙂", "🍕"]).first?.emoji == "🙂")
    }

    /// History separates ties and nothing more. Were it to outrank the match itself,
    /// one use of 🚒 would take `:fire` away from 🔥.
    @Test func doesNotLetHistoryBeatACloserMatch() {
        #expect(EmojiShortcodeIndex.matches(for: "fire", recents: ["🚒"]).first?.emoji == "🔥")
    }

    /// Reactions come back from Chat without the variation selector the catalogue
    /// carries, and both spellings have to count as the same habit.
    @Test func recognisesRememberedEmojiWithoutTheVariationSelector() {
        #expect(EmojiShortcodeIndex.matches(for: "hea", recents: ["❤"]).first?.emoji == "❤️")
    }

    // MARK: - Derivation

    /// The point of deriving from ICU: emoji nobody wrote an alias for are still
    /// reachable by their Unicode name.
    @Test(arguments: [("party_popper", "🎉"), ("rocket", "🚀"), ("fire", "🔥")])
    func derivesShortcodesFromUnicodeNames(_ shortcode: String, _ emoji: String) {
        #expect(EmojiShortcodeIndex.emoji(forShortcode: shortcode) == emoji)
    }

    @Test func buildsAUsablyLargeIndex() {
        #expect(EmojiShortcodeIndex.all.count > 400)
        #expect(EmojiShortcodeIndex.all.allSatisfy { !$0.shortcode.isEmpty })
    }

    /// Shortcodes are the identity of a row in the list, so they cannot repeat.
    @Test func hasUniqueShortcodes() {
        let codes = EmojiShortcodeIndex.all.map(\.shortcode)
        #expect(Set(codes).count == codes.count)
    }
}
