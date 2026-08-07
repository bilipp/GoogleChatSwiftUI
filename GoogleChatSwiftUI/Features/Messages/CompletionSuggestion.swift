import Foundation

/// A row of whichever completion list the composer currently has open.
///
/// One list, not two. The composer's key handling — arrows to walk the rows, Tab and
/// Return to take one, Escape to close — is the same whether the rows are emoji or
/// people, and a second set of state to keep in step with the first is how "both lists
/// are open at once" gets in. The trailing fragment is a `:shortcode` or an `@name` and
/// cannot be both, so a single homogeneous array says exactly what is true.
enum CompletionSuggestion: Identifiable, Equatable {
    case emoji(EmojiShortcode)
    case mention(MentionCandidate)

    var id: String {
        switch self {
        case .emoji(let match): "emoji:\(match.id)"
        case .mention(let candidate): "mention:\(candidate.id)"
        }
    }

    var emoji: EmojiShortcode? {
        if case .emoji(let match) = self { return match }
        return nil
    }

    var mention: MentionCandidate? {
        if case .mention(let candidate) = self { return candidate }
        return nil
    }
}
