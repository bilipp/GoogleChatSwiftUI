import AppKit
import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import GoogleChatSwiftUI

/// Chat has two entirely separate ways of carrying a GIF, and the app has to draw both the
/// same. One is an uploaded `image/gif` file, which arrives as an attachment with a media
/// resource behind it. The other is a GIF chosen from Chat's picker, which is not an
/// attachment at all: `attachedGifs` carries a public CDN URL and nothing else — no
/// filename, no resource, and no `text`, so a message that is only a GIF used to reach the
/// transcript as a blank bubble.
///
/// These tests pin what gets stored for the second kind, what the surfaces that cannot draw
/// a picture say about it, and the two pieces of drawing that decide whether either kind
/// actually moves.
@MainActor
struct AttachedGifTests {
    // MARK: - Fixtures

    private func makeStore() throws -> (ChatStore, ModelContainer) {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (ChatStore(modelContainer: container), container)
    }

    private func space() throws -> ChatSpace {
        let json = #"{"name":"spaces/A","spaceType":"SPACE","spaceThreadingState":"THREADED_MESSAGES"}"#
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    /// Decoded rather than built with the memberwise initialiser, so these stay valid as the
    /// DTOs gain fields — and so the shape under test is the shape Chat actually sends.
    ///
    /// - Parameters:
    ///   - text: the comment alongside the GIF. Empty in the common case, and the reason a
    ///     GIF cannot be treated as decoration on a message.
    ///   - gifs: `attachedGifs` verbatim, so a test can hand over a malformed one.
    private func gifMessage(
        _ id: String = "m1",
        text: String = "",
        gifs: String = #"[{"uri":"https://media.tenor.com/qLogjAQgzggAAAAC/lotr.gif"}]"#
    ) throws -> ChatMessage {
        let body = text.isEmpty ? "" : #""text":"\#(text)","#
        let json = """
        {
          "name":"spaces/A/messages/\(id).\(id)",
          \(body)
          "createTime":"2026-08-20T18:40:32Z",
          "sender":{"name":"users/tomas","type":"HUMAN"},
          "thread":{"name":"spaces/A/threads/\(id)"},
          "threadReply":true,
          "attachedGifs":\(gifs)
        }
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func stored(
        _ remote: ChatMessage,
        in store: ChatStore,
        container: ModelContainer
    ) async throws -> CachedMessage {
        try await store.upsertSpaces([try space()])
        try await store.mergeMessages([remote], into: "spaces/A")
        let context = ModelContext(container)
        let name = remote.name
        return try #require(
            try context.fetch(
                FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.name == name })
            ).first
        )
    }

    // MARK: - Decoding

    @Test("A picker GIF decodes off attachedGifs, not attachment")
    func decodesAttachedGifs() throws {
        let message = try gifMessage()

        #expect(message.attachedGifs?.count == 1)
        #expect(message.attachedGifs?.first?.uri == "https://media.tenor.com/qLogjAQgzggAAAAC/lotr.gif")
        // The distinction the whole feature rests on: this is not an uploaded file, so
        // there is no attachment, no filename and no media resource to fetch.
        #expect(message.attachment == nil)
    }

    /// `uri` is the only field `AttachedGif` has, and it is documented as optional. A
    /// payload without one must not take the message down with it — the rest of what was
    /// sent is still worth showing.
    @Test("A GIF with no URI is dropped rather than failing the message")
    func toleratesGifWithoutURI() async throws {
        let (store, container) = try makeStore()
        let message = try gifMessage(
            text: "look at this",
            gifs: #"[{},{"uri":"https://media.tenor.com/a.gif"}]"#
        )

        let cached = try await stored(message, in: store, container: container)

        #expect(cached.attachedGifURIs == ["https://media.tenor.com/a.gif"])
        #expect(cached.text == "look at this")
    }

    // MARK: - Storage

    @Test("GIF URLs survive the round trip into the cache")
    func storesGifURIs() async throws {
        let (store, container) = try makeStore()

        let cached = try await stored(try gifMessage(), in: store, container: container)

        #expect(cached.attachedGifURIs == ["https://media.tenor.com/qLogjAQgzggAAAAC/lotr.gif"])
        #expect(cached.hasGifs)
    }

    /// `apply` writes the field unconditionally, for the reason the forward columns are
    /// written that way: an edit that removed the GIF has to clear the row rather than leave
    /// a picture behind that the message no longer carries.
    @Test("An edit that drops the GIF clears the stored URLs")
    func clearsGifURIsOnEdit() async throws {
        let (store, container) = try makeStore()
        let cached = try await stored(try gifMessage(), in: store, container: container)
        #expect(cached.hasGifs)

        let edited = try gifMessage(text: "never mind", gifs: "[]")
        try await store.mergeMessages([edited], into: "spaces/A")

        let context = ModelContext(container)
        let name = edited.name
        let after = try #require(
            try context.fetch(
                FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.name == name })
            ).first
        )
        #expect(after.attachedGifURIs.isEmpty)
        #expect(!after.hasGifs)
    }

    // MARK: - What the text surfaces say

    /// The bubble is omitted for an empty `displayText`, which is what a GIF wants: the
    /// picture renders as its own block beneath, and a bubble reading "GIF" above it would
    /// be describing the block rather than the message.
    @Test("A GIF-only message asks for no bubble but still summarises as one")
    func gifOnlyMessageHasNoBubbleText() async throws {
        let (store, container) = try makeStore()

        let cached = try await stored(try gifMessage(), in: store, container: container)

        #expect(cached.displayText.isEmpty)
        // Notifications, the menu bar, the thread list and VoiceOver all read this, and
        // none of them can draw a picture. "Message" would say nothing at all.
        #expect(cached.summaryText == "GIF")
    }

    @Test("A comment alongside a GIF is what both surfaces show")
    func commentWinsOverGifPlaceholder() async throws {
        let (store, container) = try makeStore()

        let cached = try await stored(
            try gifMessage(text: "this is us"),
            in: store,
            container: container
        )

        #expect(cached.displayText == "this is us")
        #expect(cached.summaryText == "this is us")
    }

    /// The wire model has its own copy of this fallback, used for the notification banner
    /// raised straight off an event before anything is cached.
    @Test("The wire model summarises a GIF too")
    func remoteMessageDescribesGif() throws {
        #expect(try gifMessage().displayText == "GIF")
        #expect(try gifMessage(text: "this is us").displayText == "this is us")
    }

    // MARK: - Drawing

    /// Whether a picture animates is decided by its frame count rather than by its MIME
    /// type, because the type lies in both directions: plenty of `image/gif` files are a
    /// single frame, and an animated one can arrive under a type nobody checked for.
    @Test("Animation is decided by frame count, not by file type")
    func detectsAnimation() throws {
        let animated = try #require(NSImage(data: try Self.gifData(frames: 2)))
        let single = try #require(NSImage(data: try Self.gifData(frames: 1)))

        #expect(animated.isAnimated)
        #expect(!single.isAnimated)
        // A PNG has no frame count at all, and asking must not crash or claim it moves.
        let png = NSImage(size: CGSize(width: 4, height: 4))
        #expect(!png.isAnimated)
    }

    @Test("A picture is scaled down to the preview cap but never up")
    func scalesToFit() {
        let limit = CGSize(width: 320, height: 240)

        // Wider than the cap: bounded by width, proportions kept.
        #expect(CGSize(width: 640, height: 240).scaledToFit(limit) == CGSize(width: 320, height: 120))
        // Taller than the cap: bounded by height instead.
        #expect(CGSize(width: 240, height: 480).scaledToFit(limit) == CGSize(width: 120, height: 240))
        // Smaller than the cap is left alone — blowing a 12-point emoji GIF up to 320
        // points only makes it blurry.
        let small = CGSize(width: 100, height: 50)
        #expect(small.scaledToFit(limit) == small)
        // An image that reported no size falls back to the cap, since a zero-sized frame
        // draws nothing at all.
        #expect(CGSize.zero.scaledToFit(limit) == limit)
    }

    /// A GIF of `frames` 1×1 frames, so `isAnimated` is tested against a real multi-frame
    /// bitmap rather than a stub that claims to be one.
    private static func gifData(frames: Int) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frames, nil)
        )
        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )

        let context = try #require(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let frame = try #require(context.makeImage())

        for _ in 0..<frames {
            CGImageDestinationAddImage(
                destination,
                frame,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            )
        }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
