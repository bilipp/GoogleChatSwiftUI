import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import GoogleChatSwiftUI

/// Pasting into the composer has to make a judgement the user never sees: a pasteboard
/// routinely holds a picture and words at the same time, and guessing wrong either
/// attaches a screenshot of the paragraph someone meant to quote, or drops the
/// screenshot they meant to send. These pin that judgement down.
@MainActor
struct PasteboardImageTests {
    /// A private pasteboard per test, so nothing here touches what the user has copied.
    private func pasteboard(_ name: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("GoogleChatSwiftUITests.\(name)"))
        board.clearContents()
        return board
    }

    private var pngData: Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - Bytes

    @Test func stagesPastedImageBytes() throws {
        let board = pasteboard("bytes")
        board.declareTypes([.png], owner: nil)
        board.setData(pngData, forType: .png)

        let staged = try #require(PasteboardImages.attachments(on: board).first)
        #expect(staged.filename == "Pasted image.png")
        #expect(staged.mimeType == "image/png")
        #expect(staged.isImage)
        #expect(staged.data == pngData)
    }

    @Test func numbersImagesOnlyWhenAPasteBringsSeveral() {
        let board = pasteboard("several")
        let items = (0..<2).map { _ -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setData(pngData, forType: .png)
            return item
        }
        board.writeObjects(items)

        let staged = PasteboardImages.attachments(on: board)
        #expect(staged.map(\.filename) == ["Pasted image 1.png", "Pasted image 2.png"])
    }

    @Test func keepsTheFlavourItWasCopiedAs() throws {
        let board = pasteboard("flavour")
        let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        board.declareTypes([jpeg], owner: nil)
        board.setData(pngData, forType: jpeg)

        let staged = try #require(PasteboardImages.attachments(on: board).first)
        #expect(staged.filename == "Pasted image.jpeg")
        #expect(staged.mimeType == "image/jpeg")
    }

    // MARK: - Picture or words

    @Test func stagesTheImageWhenTheCopyingAppOfferedItFirst() {
        let board = pasteboard("imageFirst")
        board.declareTypes([.png, .string], owner: nil)
        board.setData(pngData, forType: .png)
        board.setString("https://example.com/cat.png", forType: .string)

        #expect(PasteboardImages.attachments(on: board).count == 1)
    }

    /// A word processor puts a rendered image beside copied text. Pasting that has to
    /// leave the keystroke to the text field, or quoting anything attaches a picture.
    @Test func leavesTextAloneWhenItWasOfferedFirst() {
        let board = pasteboard("textFirst")
        board.declareTypes([.string, .png], owner: nil)
        board.setString("ship the parser today", forType: .string)
        board.setData(pngData, forType: .png)

        #expect(PasteboardImages.attachments(on: board).isEmpty)
    }

    @Test func stagesNothingForAPlainTextCopy() {
        let board = pasteboard("textOnly")
        board.declareTypes([.string], owner: nil)
        board.setString("ship the parser today", forType: .string)

        #expect(PasteboardImages.attachments(on: board).isEmpty)
    }

    @Test func stagesNothingForAnEmptyClipboard() {
        #expect(PasteboardImages.attachments(on: pasteboard("empty")).isEmpty)
    }

    // MARK: - Files

    @Test func keepsTheNameOfAnImageCopiedInTheFinder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("architecture-diagram.png")
        try pngData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let board = pasteboard("file")
        board.writeObjects([url as NSURL])

        let staged = try #require(PasteboardImages.attachments(on: board).first)
        #expect(staged.filename == "architecture-diagram.png")
        #expect(staged.mimeType == "image/png")
    }

    /// The Finder offers the file's path as a string too. Attaching still beats pasting
    /// that path into the message, which is what the ordering rule would otherwise do.
    @Test func prefersACopiedImageFileToItsPath() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenshot.png")
        try pngData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let board = pasteboard("filePath")
        board.declareTypes([.string, .fileURL], owner: nil)
        board.setString(url.path, forType: .string)
        board.setString(url.absoluteString, forType: .fileURL)

        #expect(PasteboardImages.attachments(on: board).count == 1)
    }

    @Test func stagesNothingForACopiedFileThatIsNotAnImage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes.txt")
        try "ship the parser today".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let board = pasteboard("nonImageFile")
        board.writeObjects([url as NSURL])

        #expect(PasteboardImages.attachments(on: board).isEmpty)
    }
}
