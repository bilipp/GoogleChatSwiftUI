import Foundation

/// Someone the composer can offer to mention.
nonisolated struct MentionCandidate: Hashable, Identifiable, Sendable {
    /// Chat resource name, e.g. `users/1234567890`, or ``everyoneName``.
    let userName: String
    /// How the mention reads in the message — the directory's name for this person,
    /// which is also what Chat itself renders the annotation as.
    let displayName: String
    let photoURL: String?

    var id: String { userName }

    /// Chat's own name for "everyone in this space". It is a real user resource as far
    /// as the API is concerned, which is why it can travel through the same type as a
    /// person rather than needing a case of its own.
    static let everyoneName = "users/all"

    var isEveryone: Bool { userName == Self.everyoneName }

    /// The whole room, in one mention.
    static let everyone = MentionCandidate(
        userName: everyoneName,
        displayName: "all",
        photoURL: nil
    )
}

/// Deliberately *not* `nonisolated`, unlike the type it extends: `CachedUser` is a
/// SwiftData model and therefore main-actor isolated under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so reading one has to happen where the
/// views that pass it in already are. The candidate itself stays nonisolated, which is
/// what lets it travel down to the send path.
extension MentionCandidate {
    /// Builds a space's candidate list from its member IDs and the directory rows the
    /// view already has to hand.
    ///
    /// Members whose profile has not been resolved yet are left out rather than shown
    /// as "Unknown": a mention is written as a name, so someone with no name is not
    /// something the composer can offer. They appear as soon as the People lookup
    /// lands, the same way the transcript fills in its senders.
    ///
    /// - Parameter userIDs: the space's members, the signed-in user already removed.
    static func list(for userIDs: [String], users: [String: CachedUser]) -> [MentionCandidate] {
        var result: [MentionCandidate] = []
        for id in userIDs {
            guard let user = users[id], let displayName = user.displayName, !displayName.isEmpty
            else { continue }
            result.append(
                MentionCandidate(userName: id, displayName: displayName, photoURL: user.photoURL)
            )
        }
        // `@all` needs more than one other person to mean anything: in a DM it would
        // only be a louder way of addressing the one person already being written to.
        if result.count > 1 { result.append(.everyone) }
        return result
    }
}

/// Ranks a space's members against the fragment being typed.
nonisolated enum MentionDirectory {
    /// How many people the composer offers at once. Larger than the emoji list, since
    /// a name is scanned for rather than read, and a room's members are a finite set
    /// the user is expected to recognise.
    static let suggestionLimit = 10

    /// Candidates matching `query`, best first.
    ///
    /// Ranked in three tiers — the whole name starting with the query, any word of it
    /// starting with the query, then a match anywhere. That ordering is what puts
    /// "Ada Lovelace" above "Miranda Ada-Smith" for `ad`, and still reaches someone
    /// whose surname is all you remember.
    ///
    /// An empty query lists everyone, which is what a bare `@` should show.
    static func matches(
        for query: String,
        in candidates: [MentionCandidate],
        limit: Int = suggestionLimit
    ) -> [MentionCandidate] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return Array(candidates.sorted { $0.displayName < $1.displayName }.prefix(limit))
        }

        // Built as a loop rather than a filter/map/sorted chain: the equivalent
        // pipeline over a tuple exceeds the type checker's budget, as it does
        // elsewhere in this app.
        var ranked: [(rank: Int, candidate: MentionCandidate)] = []
        for candidate in candidates {
            guard let rank = rank(of: candidate, matching: needle) else { continue }
            ranked.append((rank, candidate))
        }

        ranked.sort { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            return left.candidate.displayName < right.candidate.displayName
        }
        return Array(ranked.prefix(limit).map(\.candidate))
    }

    /// Lower is a better match. Nil when the name does not contain the query at all.
    private static func rank(of candidate: MentionCandidate, matching needle: String) -> Int? {
        let name = candidate.displayName.lowercased()
        if name.hasPrefix(needle) { return 0 }
        for word in name.split(separator: " ") where word.hasPrefix(needle) { return 1 }
        return name.contains(needle) ? 2 : nil
    }
}

/// Turns the `@Display Name` the user sees into the `<users/123>` Chat's API expects.
///
/// Chat has no structured field for mentions on the way out: a message carries them as
/// this markup inside `text`, and answers with `USER_MENTION` annotations on the way
/// back in. So the composer keeps a readable draft and the wire form is derived from
/// it at the last moment — the same split the local echo relies on, which shows what
/// was typed rather than the markup that was sent.
///
/// Names are matched rather than offsets recorded, for the reason
/// ``ChatTextRenderer`` gives for doing the same in the other direction: an offset
/// captured when a name was inserted is wrong the moment anything before it is edited,
/// and people edit the middle of a sentence constantly.
nonisolated enum MentionEncoder {
    /// Rewrites every mention `text` still contains.
    ///
    /// A name the user has since deleted simply is not found, so a mention backed out
    /// of costs nothing. A name typed out by hand that happens to match a candidate is
    /// encoded too, which is the behaviour someone typing it would expect.
    static func encode(_ text: String, mentions: [MentionCandidate]) -> String {
        guard !mentions.isEmpty, text.contains("@") else { return text }
        // Longest first, so `@Ana` cannot claim the opening of `@Ana Silva`.
        let ordered = mentions.sorted { $0.displayName.count > $1.displayName.count }

        var result = ""
        var index = text.startIndex
        var previous: Character?

        while index < text.endIndex {
            let character = text[index]
            let opensWord = previous.map { $0.isWhitespace || $0.isNewline } ?? true

            guard character == "@", opensWord else {
                result.append(character)
                previous = character
                index = text.index(after: index)
                continue
            }

            let afterAt = text.index(after: index)
            guard let matched = candidate(in: text[afterAt...], among: ordered) else {
                result.append(character)
                previous = character
                index = afterAt
                continue
            }

            result.append("<\(matched.userName)>")
            index = text.index(afterAt, offsetBy: matched.displayName.count)
            // The next character is judged against the name, not the markup that
            // replaced it, so `@Ada@Ben` keeps behaving like the text it came from.
            previous = matched.displayName.last
        }
        return result
    }

    /// The candidate whose name `rest` opens with, ending on a word boundary.
    private static func candidate(
        in rest: Substring,
        among ordered: [MentionCandidate]
    ) -> MentionCandidate? {
        for candidate in ordered where rest.hasPrefix(candidate.displayName) {
            let end = rest.index(rest.startIndex, offsetBy: candidate.displayName.count)
            // The name has to end where the word does. Without this `@Ana` would
            // swallow the front of a colleague called Anastasia.
            if end == rest.endIndex || !isWordCharacter(rest[end]) { return candidate }
        }
        return nil
    }

    /// Narrower than ``MentionTrigger/isNameCharacter(_:)``, and deliberately so: a
    /// space ends a mention here, or `@Ana` inside "@Ana Silva said" could never be
    /// encoded when only Ana is the one being mentioned.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
