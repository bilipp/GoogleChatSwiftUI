import Foundation
import Testing

@testable import GoogleChatSwiftUI

/// The URL⇄resource-name mapping is undocumented, so these cases are the specification:
/// every pairing below was taken from a `CHAT_SPACE` rich-link annotation, where Chat
/// states the link and the `spaces/…` names it resolves to side by side. Getting the
/// mapping wrong is quiet in both directions — a copied link opens the wrong message or
/// nothing at all, and a followed one lands the reader somewhere they did not ask for.
struct ChatDeepLinkTests {
    // MARK: - Reading a link

    /// The pairing Chat itself published, for a message that is its thread's root.
    @Test func readsAMessageLinkInASpace() throws {
        let link = try #require(
            ChatDeepLink(url: url("https://chat.google.com/room/AAQAmGXKxuo/5SkDl31Qz-E/5SkDl31Qz-E?cls=10"))
        )
        #expect(link.spaceName == "spaces/AAQAmGXKxuo")
        #expect(link.threadName == "spaces/AAQAmGXKxuo/threads/5SkDl31Qz-E")
        #expect(link.messageName == "spaces/AAQAmGXKxuo/messages/5SkDl31Qz-E.5SkDl31Qz-E")
    }

    /// The case that proves the two segments are not simply the same id twice: a reply
    /// carries its thread's id first and its own second.
    @Test func readsAReplyWhoseIDDiffersFromItsThread() throws {
        let link = try #require(
            ChatDeepLink(url: url("https://chat.google.com/room/AAQAA_vg0rg/nxaMihFK0bw/MBJaRMLeD4s?cls=10"))
        )
        #expect(link.threadName == "spaces/AAQAA_vg0rg/threads/nxaMihFK0bw")
        #expect(link.messageName == "spaces/AAQAA_vg0rg/messages/nxaMihFK0bw.MBJaRMLeD4s")
    }

    /// A direct message is addressed with `dm`, and carries its space id unchanged —
    /// so the prefix affects nothing but which word appears in the link.
    @Test func readsAMessageLinkInADirectMessage() throws {
        let link = try #require(
            ChatDeepLink(url: url("https://chat.google.com/dm/5kdutAAAAAE/kkfryVE9bRg/kkfryVE9bRg?cls=10"))
        )
        #expect(link.spaceName == "spaces/5kdutAAAAAE")
        #expect(link.messageName == "spaces/5kdutAAAAAE/messages/kkfryVE9bRg.kkfryVE9bRg")
    }

    /// Chat tags its own copied links with `?cls=`; people paste them with the query
    /// stripped. Both have to resolve to the same message.
    @Test func ignoresTheClickSourceQuery() throws {
        let withTag = ChatDeepLink(
            url: url("https://chat.google.com/room/AAAAm_aWjVo/wnnFGbCbB4M/wnnFGbCbB4M?cls=10")
        )
        let without = ChatDeepLink(
            url: url("https://chat.google.com/room/AAAAm_aWjVo/wnnFGbCbB4M/wnnFGbCbB4M")
        )
        #expect(withTag == without)
    }

    @Test func readsAConversationLinkWithNoMessage() throws {
        let link = try #require(ChatDeepLink(url: url("https://chat.google.com/room/AAQAmGXKxuo?cls=7")))
        #expect(link.spaceName == "spaces/AAQAmGXKxuo")
        #expect(link.threadName == nil)
        #expect(link.messageName == nil)
    }

    /// A thread with no message after it. Two segments rather than three, so there is a
    /// thread to open but no row to scroll to.
    @Test func readsAThreadLink() throws {
        let link = try #require(ChatDeepLink(url: url("https://chat.google.com/room/AAAAW0-4CC4/bTxfweFkhFk")))
        #expect(link.threadName == "spaces/AAAAW0-4CC4/threads/bTxfweFkhFk")
        #expect(link.messageName == nil)
    }

    /// The form the installed-app shortcut produces, and the account-scoped and
    /// fragment routes. All three put the space id after a word this parser knows.
    @Test(arguments: [
        "https://chat.google.com/app/chat/AAQAb3gfHGU",
        "https://chat.google.com/u/0/room/AAQAb3gfHGU",
        "https://chat.google.com/u/0/#chat/space/AAQAb3gfHGU",
    ])
    func readsTheOtherRoutesToAConversation(_ text: String) throws {
        let link = try #require(ChatDeepLink(url: url(text)))
        #expect(link.spaceName == "spaces/AAQAb3gfHGU")
    }

    /// Everything else on the web belongs to the browser. `mail.google.com/chat` is in
    /// this list deliberately: it is a route to Chat, but not one this parser claims.
    @Test(arguments: [
        "https://example.com/room/AAQAmGXKxuo/x/y",
        "https://chat.google.com",
        "https://chat.google.com/room",
        "https://chat.google.com/room/",
        "https://mail.google.com/chat/u/0/#chat/space/AAQAb3gfHGU",
        "https://docs.google.com/document/d/abc/edit",
    ])
    func declinesEverythingElse(_ text: String) {
        #expect(ChatDeepLink(url: url(text)) == nil)
    }

    // MARK: - Writing a link

    /// Round-trips against the pairing Chat published: the link built for a message
    /// name has to be the link Chat would have copied for it.
    @Test func buildsTheLinkChatWouldHaveCopied() throws {
        let built = try #require(
            ChatDeepLink.messageURL(
                for: "spaces/AAQAA_vg0rg/messages/nxaMihFK0bw.MBJaRMLeD4s",
                spaceURI: "https://chat.google.com/room/AAQAA_vg0rg",
                spaceType: .space
            )
        )
        #expect(built.absoluteString == "https://chat.google.com/room/AAQAA_vg0rg/nxaMihFK0bw/MBJaRMLeD4s")
        // And reads back as the message it was built for.
        #expect(ChatDeepLink(url: built)?.messageName == "spaces/AAQAA_vg0rg/messages/nxaMihFK0bw.MBJaRMLeD4s")
    }

    /// The word each kind of conversation is addressed by, checked against the web
    /// client rather than reasoned about. A group chat is the one worth pinning: it is
    /// named from its members like a direct message and grouped beside them in the
    /// sidebar, and is nonetheless a `room` — only its id gives that away.
    @Test(arguments: [
        (ChatSpace.SpaceType.space, "room"),
        (ChatSpace.SpaceType.groupChat, "room"),
        (ChatSpace.SpaceType.directMessage, "dm"),
    ])
    func addressesEachKindOfConversationByItsOwnWord(
        _ type: ChatSpace.SpaceType,
        _ word: String
    ) throws {
        let built = try #require(
            ChatDeepLink.messageURL(
                for: "spaces/AAAAkdSpJ48/messages/bTxfweFkhFk.bTxfweFkhFk",
                spaceURI: nil,
                spaceType: type
            )
        )
        #expect(
            built.absoluteString
                == "https://chat.google.com/\(word)/AAAAkdSpJ48/bTxfweFkhFk/bTxfweFkhFk"
        )
    }

    /// A stored URI outranks the type. Nothing populates one today — `spaces.list` does
    /// not return the field — so this is what would carry the app through Chat changing
    /// how it addresses a conversation.
    @Test func prefersGooglesOwnURIOverTheSpaceType() throws {
        let built = try #require(
            ChatDeepLink.messageURL(
                for: "spaces/5kdutAAAAAE/messages/kkfryVE9bRg.kkfryVE9bRg",
                spaceURI: "https://chat.google.com/dm/5kdutAAAAAE",
                spaceType: .space
            )
        )
        #expect(built.absoluteString == "https://chat.google.com/dm/5kdutAAAAAE/kkfryVE9bRg/kkfryVE9bRg")
    }

    /// A trailing slash or a query on the stored URI must not reach the built link.
    @Test func tidiesTheStoredURI() throws {
        let built = try #require(
            ChatDeepLink.messageURL(
                for: "spaces/AAAAW0-4CC4/messages/bTxfweFkhFk.bTxfweFkhFk",
                spaceURI: "https://chat.google.com/room/AAAAW0-4CC4/?cls=7",
                spaceType: nil
            )
        )
        #expect(built.absoluteString == "https://chat.google.com/room/AAAAW0-4CC4/bTxfweFkhFk/bTxfweFkhFk")
    }

    /// A locally-composed placeholder is keyed by a client id, which has no thread half
    /// to put in a link. Better no menu item than a link to nothing.
    @Test func refusesAMessageStillInFlight() {
        let pending = ChatDeepLink.messageURL(
            for: "spaces/AAQAmGXKxuo/messages/9F1C6E90-2A2B-4E7E-9E43-27C0A2E2A0B1",
            spaceURI: "https://chat.google.com/room/AAQAmGXKxuo",
            spaceType: .space
        )
        #expect(pending == nil)
    }

    @Test(arguments: [
        "spaces/AAQAmGXKxuo/threads/5SkDl31Qz-E",
        "spaces/AAQAmGXKxuo",
        "AAQAmGXKxuo",
        "",
    ])
    func refusesWhatIsNotAMessageName(_ name: String) {
        #expect(ChatDeepLink.messageURL(for: name, spaceURI: nil, spaceType: .space) == nil)
    }

    // MARK: - Writing a link to a conversation

    /// A conversation link is a message link with the thread and message left off, and
    /// picks its word the same way — the group chat again being the one that has to be
    /// checked rather than reasoned about.
    @Test(arguments: [
        (ChatSpace.SpaceType.space, "room"),
        (ChatSpace.SpaceType.groupChat, "room"),
        (ChatSpace.SpaceType.directMessage, "dm"),
    ])
    func buildsAConversationLink(_ type: ChatSpace.SpaceType, _ word: String) throws {
        let built = try #require(
            ChatDeepLink.spaceURL(for: "spaces/AAQAA_vg0rg", spaceURI: nil, spaceType: type)
        )
        #expect(built.absoluteString == "https://chat.google.com/\(word)/AAQAA_vg0rg")
        // And reads back as the conversation it was built for, naming nothing narrower.
        let read = try #require(ChatDeepLink(url: built))
        #expect(read.spaceName == "spaces/AAQAA_vg0rg")
        #expect(read.threadName == nil)
        #expect(read.messageName == nil)
    }

    /// The stored URI outranks the type here too, and is tidied the same way: no
    /// trailing slash, and no `?cls=` claiming the reader's click came from this app.
    @Test func tidiesTheStoredURIForAConversation() throws {
        let built = try #require(
            ChatDeepLink.spaceURL(
                for: "spaces/AAAAW0-4CC4",
                spaceURI: "https://chat.google.com/dm/AAAAW0-4CC4/?cls=7",
                spaceType: .space
            )
        )
        #expect(built.absoluteString == "https://chat.google.com/dm/AAAAW0-4CC4")
    }

    @Test(arguments: [
        "spaces/AAQAmGXKxuo/threads/5SkDl31Qz-E",
        "spaces/AAQAmGXKxuo/messages/5SkDl31Qz-E.5SkDl31Qz-E",
        "AAQAmGXKxuo",
        "spaces/",
        "spaces",
        "",
    ])
    func refusesWhatIsNotASpaceName(_ name: String) {
        #expect(ChatDeepLink.spaceURL(for: name, spaceURI: nil, spaceType: .space) == nil)
    }

    private func url(_ text: String) -> URL {
        URL(string: text)!
    }
}
