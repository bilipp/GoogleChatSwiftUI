import Foundation

/// One attachment, reduced to what it takes to show and fetch it.
///
/// A value rather than the ``CachedAttachment`` row, because not every attachment the
/// transcript renders *is* a row. A forwarded message brings copies of the original's
/// attachment metadata, and those are stored as JSON on the message that forwarded them
/// rather than as rows of their own — see ``CachedMessage/quotedAttachmentsJSON`` for why
/// that key cannot be shared. Both shapes reduce to the same handful of facts, so the chip
/// renders either and neither knows about the other.
nonisolated struct AttachmentDisplay: Identifiable, Sendable, Equatable {
    /// Stable within one message, which is all a `ForEach` needs. Chat's own resource name
    /// wherever there is one; a forwarded attachment that arrived without one falls back to
    /// its position, since two nameless files in one message still have to be told apart.
    let id: String
    /// The filename, when Chat supplied one.
    let contentName: String?
    let contentType: String?
    /// Link for a human in a browser. The only route to a Drive-hosted file, which has no
    /// media resource behind it.
    let downloadURI: String?
    /// Pointer for `media.download`, absent for Drive-hosted files.
    let dataResourceName: String?

    var displayName: String { contentName ?? "Attachment" }

    var isImage: Bool { contentType?.hasPrefix("image/") ?? false }

    /// Drive-hosted attachments have no media resource and must open in a browser.
    var isDownloadable: Bool { dataResourceName != nil }

    var symbol: String {
        guard let type = contentType else { return "doc" }
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        return "doc"
    }
}

/// `nonisolated` is load-bearing, as on `ChatClient`'s extensions: with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unannotated extension is inferred
/// main-actor, and these initialisers are called from `CachedAttachment`, which is not.
nonisolated extension AttachmentDisplay {
    init(_ cached: CachedAttachment) {
        id = cached.name
        contentName = cached.contentName
        contentType = cached.contentType
        downloadURI = cached.downloadURI
        dataResourceName = cached.dataResourceName
    }

    /// - Parameter position: index within the message's own list, for the id of an
    ///   attachment Chat named nothing.
    init(_ remote: ChatAttachment, position: Int) {
        id = remote.name ?? "attachment-\(position)"
        contentName = remote.contentName
        contentType = remote.contentType
        downloadURI = remote.downloadUri
        dataResourceName = remote.attachmentDataRef?.resourceName
    }
}
