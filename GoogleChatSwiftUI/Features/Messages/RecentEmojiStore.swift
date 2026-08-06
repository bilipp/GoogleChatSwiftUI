import Foundation
import Observation

/// Tracks which emoji this user actually reacts with, most recent first.
///
/// Lives in `UserDefaults` rather than SwiftData: it is a small user preference, not
/// cached server state, and it should survive the cache being rebuilt.
@MainActor
@Observable
final class RecentEmojiStore {
    private static let storageKey = "recentReactionEmoji"

    /// How many to remember. Beyond roughly a dozen the tail is never reached, and
    /// the suggestion row only shows the first handful anyway.
    private static let historyLimit = 24

    /// How many appear in the quick row.
    private static let suggestionCount = 8

    /// Shown before the user has reacted to anything. Without a seed the picker
    /// would open empty on first use, which reads as broken rather than new.
    static let seeds = ["👍", "❤️", "😂", "🎉", "👀", "🙏", "✅", "😢"]

    private let defaults: UserDefaults
    private(set) var recents: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    /// Quick-row contents: the user's own history first, topped up with seeds so the
    /// row is always full and its length never jumps around as history grows.
    var suggestions: [String] {
        var result = recents
        for seed in Self.seeds where !result.contains(seed) {
            guard result.count < Self.suggestionCount else { break }
            result.append(seed)
        }
        return Array(result.prefix(Self.suggestionCount))
    }

    /// Records a reaction the user added.
    ///
    /// Only additions are recorded — removing a reaction is not a signal that the
    /// user wants to use that emoji again.
    func record(_ emoji: String) {
        var updated = recents
        // Re-reacting with an existing favourite should promote it, not duplicate it.
        updated.removeAll { $0 == emoji }
        updated.insert(emoji, at: 0)
        recents = Array(updated.prefix(Self.historyLimit))
        defaults.set(recents, forKey: Self.storageKey)
    }

    func clear() {
        recents = []
        defaults.removeObject(forKey: Self.storageKey)
    }
}
