import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// Mentions have three halves that can each be wrong quietly: what counts as a name
/// being typed, which colleague a fragment should offer, and — the one that actually
/// reaches other people — whether the finished draft turns into the markup Chat needs.
/// Getting the last one wrong posts `@Ada Lovelace` as prose and nobody is notified,
/// which looks exactly like a message that worked.
struct MentionTests {
    private static let ada = MentionCandidate(
        userName: "users/1",
        displayName: "Ada Lovelace",
        photoURL: nil
    )
    private static let grace = MentionCandidate(
        userName: "users/2",
        displayName: "Grace Hopper",
        photoURL: nil
    )
    /// A first name that opens another candidate's, for the boundary cases.
    private static let ana = MentionCandidate(
        userName: "users/3",
        displayName: "Ana",
        photoURL: nil
    )
    private static let anastasia = MentionCandidate(
        userName: "users/4",
        displayName: "Anastasia Petrova",
        photoURL: nil
    )

    private static let everyone = [ada, grace, ana, anastasia]

    // MARK: - Recognising a fragment

    @Test func findsFragmentAtEndOfText() throws {
        let text = "morning @ad"
        let match = try #require(MentionTrigger.pending(in: text))
        #expect(match.query == "ad")
        #expect(String(text[match.range]) == "@ad")
    }

    @Test func findsFragmentAtStartOfText() throws {
        let match = try #require(MentionTrigger.pending(in: "@grace"))
        #expect(match.query == "grace")
    }

    /// A bare `@` is a request to be shown the room, which is how Chat behaves too.
    @Test func matchesABareAtSign() throws {
        let match = try #require(MentionTrigger.pending(in: "hello @"))
        #expect(match.query.isEmpty)
    }

    /// The whole reason this trigger cannot reuse the emoji one: names have spaces.
    @Test func carriesOnAcrossTheSpaceInAName() throws {
        let match = try #require(MentionTrigger.pending(in: "cc @Ada Lov"))
        #expect(match.query == "Ada Lov")
    }

    @Test func keepsMatchingWhileTheSpaceIsBeingTyped() throws {
        let match = try #require(MentionTrigger.pending(in: "cc @Ada "))
        #expect(match.query == "Ada ")
    }

    /// An `@` glued to the preceding word is an address or a handle, not a name.
    @Test(arguments: ["mail ada@example.com", "see foo@bar", "a@b"])
    func ignoresAtSignsThatFollowAWord(_ text: String) {
        #expect(MentionTrigger.pending(in: text) == nil)
    }

    /// `@ ` is someone writing an at-sign; the rest of the line is prose.
    @Test func ignoresAnAtSignFollowedByASpace() {
        #expect(MentionTrigger.pending(in: "priced @ 40") == nil)
    }

    @Test func ignoresFragmentsThatAreNoLongerAtTheCaret() {
        #expect(MentionTrigger.pending(in: "hi @ada\n") == nil)
        #expect(MentionTrigger.pending(in: "hi @ada, thanks") == nil)
    }

    @Test func ignoresRunsTooLongToBeAName() {
        let long = String(repeating: "a", count: MentionTrigger.maximumQueryLength + 1)
        #expect(MentionTrigger.pending(in: "@\(long)") == nil)
    }

    /// Past a few words the at-sign opened a sentence, and the list would otherwise
    /// stay open for the rest of the paragraph.
    @Test func ignoresRunsSpanningTooManyWords() {
        #expect(MentionTrigger.pending(in: "@one two three four five") == nil)
    }

    /// Names outside ASCII are names. A scan that stopped at the first accent would
    /// offer completion to some colleagues and not others.
    @Test func acceptsNamesBeyondASCII() throws {
        let match = try #require(MentionTrigger.pending(in: "danke @Jürg"))
        #expect(match.query == "Jürg")
        #expect(MentionTrigger.pending(in: "@O'Brien")?.query == "O'Brien")
    }

    // MARK: - Offering people

    @Test func ranksTheNameThatStartsWithTheQueryFirst() {
        let matches = MentionDirectory.matches(for: "ada", in: Self.everyone)
        #expect(matches.first == Self.ada)
    }

    /// The surname is often all anyone remembers.
    @Test func matchesOnAnyWordOfTheName() {
        let matches = MentionDirectory.matches(for: "hopper", in: Self.everyone)
        #expect(matches.first == Self.grace)
    }

    /// Whole-name prefix beats word prefix beats "somewhere in there".
    @Test func prefersTheStrongerMatch() {
        let matches = MentionDirectory.matches(for: "ana", in: Self.everyone)
        #expect(matches.first == Self.ana)
        #expect(matches.contains(Self.anastasia))
    }

    @Test func isNotCaseSensitive() {
        #expect(MentionDirectory.matches(for: "ADA", in: Self.everyone).first == Self.ada)
    }

    /// A bare `@` should show the room, not nothing.
    @Test func listsEveryoneForAnEmptyQuery() {
        let matches = MentionDirectory.matches(for: "", in: Self.everyone)
        #expect(matches.count == Self.everyone.count)
    }

    @Test func offersNothingForNonsense() {
        #expect(MentionDirectory.matches(for: "qqzzxx", in: Self.everyone).isEmpty)
    }

    @Test func honoursTheSuggestionLimit() {
        #expect(MentionDirectory.matches(for: "a", in: Self.everyone, limit: 2).count == 2)
    }

    // MARK: - Encoding for the wire

    @Test func rewritesAMentionAsChatMarkup() {
        let encoded = MentionEncoder.encode("morning @Ada Lovelace", mentions: [Self.ada])
        #expect(encoded == "morning <users/1>")
    }

    @Test func rewritesEveryMentionInTheText() {
        let encoded = MentionEncoder.encode(
            "@Ada Lovelace and @Grace Hopper — thoughts?",
            mentions: [Self.ada, Self.grace]
        )
        #expect(encoded == "<users/1> and <users/2> — thoughts?")
    }

    /// The mention has to survive the words around it.
    @Test func keepsTheRestOfTheSentence() {
        let encoded = MentionEncoder.encode(
            "could @Ada Lovelace take a look before standup?",
            mentions: [Self.ada]
        )
        #expect(encoded == "could <users/1> take a look before standup?")
    }

    /// The case that makes this an encoder rather than a search-and-replace: a short
    /// name must not claim the opening of a longer one.
    @Test func prefersTheLongerNameWhenOneOpensTheOther() {
        let encoded = MentionEncoder.encode(
            "@Anastasia Petrova",
            mentions: [Self.ana, Self.anastasia]
        )
        #expect(encoded == "<users/4>")
    }

    /// And the mirror: a name that genuinely ends there is still encoded, even though
    /// a longer candidate shares its opening.
    @Test func stillEncodesTheShorterNameWhenItStandsAlone() {
        let encoded = MentionEncoder.encode("@Ana said so", mentions: [Self.ana, Self.anastasia])
        #expect(encoded == "<users/3> said so")
    }

    /// Backing out of a mention is deleting the name, so a mention the text no longer
    /// contains simply is not found.
    @Test func leavesDeletedMentionsAlone() {
        let encoded = MentionEncoder.encode("never mind", mentions: [Self.ada])
        #expect(encoded == "never mind")
    }

    /// An at-sign in the middle of a word belongs to an address, not a person.
    @Test func ignoresNamesThatDoNotOpenAWord() {
        let encoded = MentionEncoder.encode("mail ada@Ada Lovelace", mentions: [Self.ada])
        #expect(encoded == "mail ada@Ada Lovelace")
    }

    @Test func leavesTextWithoutMentionsUntouched() {
        let text = "shipping the parser today"
        #expect(MentionEncoder.encode(text, mentions: [Self.ada]) == text)
        #expect(MentionEncoder.encode(text, mentions: []) == text)
    }

    /// `@all` travels as a user resource like anyone else, which is what lets it share
    /// the type rather than needing a case of its own.
    @Test func encodesTheWholeSpace() {
        let encoded = MentionEncoder.encode("@all code freeze at six", mentions: [.everyone])
        #expect(encoded == "<users/all> code freeze at six")
    }

    /// A name typed out by hand rather than picked is still the person it names —
    /// which is also what makes re-typing a mention the user deleted work.
    @Test func encodesANameThatWasNeverPicked() {
        let encoded = MentionEncoder.encode("@Grace Hopper ping", mentions: [Self.ada, Self.grace])
        #expect(encoded == "<users/2> ping")
    }

    /// The draft the user reads and the string the API receives are the same text
    /// apart from the markup, so a mention at the very start still opens a word.
    @Test func encodesAMentionAtTheStartOfTheMessage() {
        #expect(MentionEncoder.encode("@Ada Lovelace", mentions: [Self.ada]) == "<users/1>")
    }

    @Test func encodesAMentionAfterALineBreak() {
        let encoded = MentionEncoder.encode("first\n@Ada Lovelace", mentions: [Self.ada])
        #expect(encoded == "first\n<users/1>")
    }

    // MARK: - Building the list

    /// Directory rows, as the views hand them over.
    private func cachedUsers(_ named: [String: String?]) throws -> [String: CachedUser] {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ChatSchemaV1.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        var users: [String: CachedUser] = [:]
        for (id, displayName) in named {
            let user = CachedUser(name: id)
            user.displayName = displayName
            context.insert(user)
            users[id] = user
        }
        return users
    }

    @Test func namesCandidatesFromTheDirectory() throws {
        let users = try cachedUsers(["users/1": "Ada Lovelace", "users/2": "Grace Hopper"])
        let candidates = MentionCandidate.list(for: ["users/1", "users/2"], users: users)

        #expect(candidates.map(\.displayName) == ["Ada Lovelace", "Grace Hopper", "all"])
        #expect(candidates.map(\.userName).prefix(2) == ["users/1", "users/2"])
    }

    /// A mention is written as a name, so a member the People lookup has not answered
    /// for yet is not something the composer can offer. They appear when it lands.
    @Test func leavesOutMembersTheDirectoryHasNotNamed() throws {
        let users = try cachedUsers([
            "users/1": "Ada Lovelace",
            "users/2": "Grace Hopper",
            "users/3": nil,
        ])
        let candidates = MentionCandidate.list(
            for: ["users/1", "users/2", "users/3"],
            users: users
        )
        #expect(!candidates.contains { $0.userName == "users/3" })
    }

    /// `@all` is only offered where "everyone" means more than one person: in a DM it
    /// would be a louder way of addressing the person already being written to.
    @Test func offersEveryoneOnlyBeyondADirectMessage() throws {
        let users = try cachedUsers(["users/1": "Ada Lovelace"])
        let dm = MentionCandidate.list(for: ["users/1"], users: users)

        #expect(dm.map(\.displayName) == ["Ada Lovelace"])
        #expect(!dm.contains { $0.isEveryone })
    }

    // MARK: - Surviving a failed send

    private func makeStore() throws -> (ChatStore, ModelContainer) {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (ChatStore(modelContainer: container), container)
    }

    /// Read through a context of the caller's own: `CachedMessage` belongs to the
    /// store's actor and cannot cross back out of it.
    private func message(_ name: String, in container: ModelContainer) throws -> CachedMessage? {
        try ModelContext(container).fetch(
            FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.name == name })
        ).first
    }

    private func space() throws -> ChatSpace {
        let json = #"{"name":"spaces/A","spaceType":"SPACE"}"#
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    /// The echo has to read as the draft did — showing `<users/1>` in the transcript
    /// while the send is in flight would be showing the user the plumbing.
    @Test func theLocalEchoShowsTheNameRatherThanTheMarkup() async throws {
        let (store, container) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.insertPendingMessage(
            clientID: "client-1",
            text: "morning @Ada Lovelace",
            spaceName: "spaces/A",
            senderName: "users/me",
            senderDisplayName: "Me",
            threadName: nil,
            wireText: "morning <users/1>"
        )

        let echoed = try message("spaces/A/messages/client-1", in: container)
        #expect(echoed?.text == "morning @Ada Lovelace")
        #expect(echoed?.wireText == "morning <users/1>")
    }

    /// A retry happens long after the composer that produced the mention is gone, so
    /// the markup has to have been written down. Without this the retry posts the name
    /// as prose and nobody is notified — a send that looks like it worked.
    @Test func aFailedSendRemembersTheMentionsItWasPostingWith() async throws {
        let (store, _) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.insertPendingMessage(
            clientID: "client-1",
            text: "morning @Ada Lovelace",
            spaceName: "spaces/A",
            senderName: "users/me",
            senderDisplayName: "Me",
            threadName: nil,
            wireText: "morning <users/1>"
        )
        try await store.markSendFailed(
            clientID: "client-1",
            spaceName: "spaces/A",
            reason: "offline"
        )

        let context = try await store.sendContext(for: "spaces/A/messages/client-1")
        #expect(context?.wireText == "morning <users/1>")
    }

    /// The overwhelming majority of messages mention nobody, and for those the two
    /// strings are the same — so the retry path falls back to the text itself.
    @Test func aMessageWithoutMentionsStoresNoSeparateWireForm() async throws {
        let (store, _) = try makeStore()
        try await store.upsertSpaces([try space()])
        try await store.insertPendingMessage(
            clientID: "client-1",
            text: "morning",
            spaceName: "spaces/A",
            senderName: "users/me",
            senderDisplayName: "Me",
            threadName: nil
        )

        let context = try await store.sendContext(for: "spaces/A/messages/client-1")
        #expect(context?.wireText == nil)
    }
}
