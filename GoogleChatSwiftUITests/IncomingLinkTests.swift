import Foundation
import Testing

@testable import GoogleChatSwiftUI

struct IncomingLinkTests {
    @Test func readsAThreadWithADraft() throws {
        let incoming = try #require(
            IncomingLink(url: url("gchat://room/AAAAllxdcpI/s4cI8GbUs4g?draft=fixed%20now%20%F0%9F%91%8D%0A%0Anext%20line"))
        )
        #expect(incoming.link.spaceName == "spaces/AAAAllxdcpI")
        #expect(incoming.link.threadName == "spaces/AAAAllxdcpI/threads/s4cI8GbUs4g")
        #expect(incoming.link.messageName == nil)
        #expect(incoming.draft == "fixed now 👍\n\nnext line")
        #expect(incoming.webURL.absoluteString == "https://chat.google.com/room/AAAAllxdcpI/s4cI8GbUs4g")
    }

    /// The same path as the web link, so a copied message link works with only its
    /// scheme and host swapped.
    @Test func readsAMessageLinkWithoutADraft() throws {
        let incoming = try #require(IncomingLink(url: url("gchat://room/AAQAA_vg0rg/nxaMihFK0bw/MBJaRMLeD4s")))
        #expect(incoming.link.messageName == "spaces/AAQAA_vg0rg/messages/nxaMihFK0bw.MBJaRMLeD4s")
        #expect(incoming.draft == nil)
    }

    @Test func readsADirectMessage() throws {
        let incoming = try #require(IncomingLink(url: url("gchat://dm/5kdutAAAAAE?draft=hi")))
        #expect(incoming.link.spaceName == "spaces/5kdutAAAAAE")
        #expect(incoming.webURL.absoluteString == "https://chat.google.com/dm/5kdutAAAAAE")
    }

    @Test func acceptsAWebLinkAndDropsItsQuery() throws {
        let incoming = try #require(
            IncomingLink(url: url("https://chat.google.com/room/AAAAllxdcpI/s4cI8GbUs4g/s4cI8GbUs4g?cls=10&draft=x"))
        )
        #expect(incoming.link.threadName == "spaces/AAAAllxdcpI/threads/s4cI8GbUs4g")
        #expect(incoming.draft == "x")
        #expect(incoming.webURL.query == nil)
    }

    @Test func treatsAnEmptyDraftAsNone() throws {
        #expect(try #require(IncomingLink(url: url("gchat://room/AAAAllxdcpI?draft="))).draft == nil)
    }

    @Test func rejectsOtherSchemesAndRoutes() {
        #expect(IncomingLink(url: url("mailto:someone@example.com")) == nil)
        #expect(IncomingLink(url: url("gchat://settings")) == nil)
        #expect(IncomingLink(url: url("https://example.com/room/AAAAllxdcpI")) == nil)
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }
}
