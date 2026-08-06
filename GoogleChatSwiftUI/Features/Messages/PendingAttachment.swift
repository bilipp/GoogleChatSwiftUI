import AppKit
import Foundation
import UniformTypeIdentifiers

/// A file staged in the composer, before it is uploaded.
///
/// Bytes are read at pick time rather than holding the URL. A sandboxed app's access
/// to a user-selected file is scoped to the picker's grant, and by the time the send
/// completes that URL may no longer be readable.
nonisolated struct PendingAttachment: Identifiable, Sendable, Equatable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data

    var isImage: Bool { mimeType.hasPrefix("image/") }

    var byteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    var symbol: String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType.contains("pdf") { return "doc.richtext" }
        return "doc"
    }

    /// Chat rejects anything larger, so it is caught here rather than after a long
    /// upload that ends in a server error.
    static let maxBytes = 200 * 1024 * 1024

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.data = data
        filename = url.lastPathComponent
        mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    /// For images pasted or dragged in as raw data, which carry no filename.
    init(imageData: Data, suggestedName: String, mimeType: String) {
        data = imageData
        filename = suggestedName
        self.mimeType = mimeType
    }

    var exceedsSizeLimit: Bool { data.count > Self.maxBytes }
}
