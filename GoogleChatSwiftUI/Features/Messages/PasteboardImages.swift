import AppKit
import UniformTypeIdentifiers

/// The images the clipboard is offering, as files the composer can stage.
///
/// Apart from the composer because what a ⌘V means is a question about the pasteboard
/// rather than about the view: an image can arrive as bytes from a screenshot, as a
/// file copied in the Finder, or not at all — and only the last of those should leave
/// the keystroke to the text field.
enum PasteboardImages {
    /// Image flavours read byte-for-byte, in the order they are worth having.
    ///
    /// PNG ahead of TIFF because a screenshot is offered as both and the TIFF runs an
    /// order of magnitude larger for the same pixels. Read rather than round-tripped
    /// through `NSImage`, so what is uploaded is what was copied.
    private static let readableTypes: [UTType] = [.png, .jpeg, .heic, .webP, .gif, .bmp, .tiff]

    /// What the clipboard has to offer this composer, or nothing.
    ///
    /// Files win over bytes when both are present: the Finder puts a URL on the
    /// pasteboard alongside the image, and the URL is the one that carries the name the
    /// sender chose.
    static func attachments(on pasteboard: NSPasteboard) -> [PendingAttachment] {
        let files = imageFiles(on: pasteboard)
        guard files.isEmpty else { return files }
        guard prefersImageToText(on: pasteboard) else { return [] }
        return imageData(on: pasteboard)
    }

    private static func imageFiles(on pasteboard: NSPasteboard) -> [PendingAttachment] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        // Asks the file what it is instead of trusting the extension, which is what a
        // ".jpg" that is really a PDF would otherwise be uploaded as.
        return urls
            .filter { url in
                let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                return type?.conforms(to: .image) ?? false
            }
            .compactMap(PendingAttachment.init(contentsOf:))
    }

    /// Whether the clipboard is offering a picture rather than words.
    ///
    /// Decided by which flavour the copying app declared first, because a pasteboard
    /// routinely holds both: a word processor puts a rendered image beside copied text,
    /// and a browser puts the source URL beside a copied image. Declaration order is
    /// that app saying which one it meant, and honouring it is what keeps ⌘V from
    /// attaching a picture of the paragraph someone was trying to quote.
    private static func prefersImageToText(on pasteboard: NSPasteboard) -> Bool {
        for flavour in pasteboard.types ?? [] {
            guard let type = UTType(flavour.rawValue) else { continue }
            if type.conforms(to: .image) { return true }
            if type.conforms(to: .text) { return false }
        }
        return false
    }

    /// One attachment per pasteboard item, so copying several images at once stages
    /// several rather than only the first.
    private static func imageData(on pasteboard: NSPasteboard) -> [PendingAttachment] {
        let images = (pasteboard.pasteboardItems ?? []).compactMap(image(in:))
        return images.enumerated().map { index, image in
            PendingAttachment(
                imageData: image.data,
                suggestedName: filename(for: image.type, index: index, of: images.count),
                mimeType: image.type.preferredMIMEType ?? "application/octet-stream"
            )
        }
    }

    private static func image(in item: NSPasteboardItem) -> (data: Data, type: UTType)? {
        for candidate in readableTypes {
            guard
                let data = item.data(forType: NSPasteboard.PasteboardType(candidate.identifier)),
                !data.isEmpty
            else { continue }
            return (data, candidate)
        }
        return nil
    }

    /// Pasted bytes carry no name, so they are given one that reads as what it is.
    /// Numbered only when a single paste brings several, since "Pasted image" twice over
    /// in one message says nothing about which is which.
    private static func filename(for type: UTType, index: Int, of count: Int) -> String {
        let stem = count > 1 ? "Pasted image \(index + 1)" : "Pasted image"
        return "\(stem).\(type.preferredFilenameExtension ?? "png")"
    }
}
