import SwiftUI
import UniformTypeIdentifiers

/// Attachment chips under a message: image previews inline, other files as a row
/// with a save action.
struct AttachmentList: View {
    let attachments: [AttachmentDisplay]
    let isOwn: Bool
    /// How wide an image preview may be drawn. Narrowed inside a forwarded message, whose
    /// block is already inset from the transcript.
    var previewLimit: CGSize = AttachmentChip.defaultPreviewLimit

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
            ForEach(attachments) { attachment in
                AttachmentChip(attachment: attachment, isOwn: isOwn, previewLimit: previewLimit)
            }
        }
    }
}

/// The Save… panel, shared by the attachment row and the image viewer so a file saved
/// from either lands with the same name and type.
@MainActor
enum AttachmentSavePanel {
    static func destination(named name: String, contentType: String?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if let contentType, let type = UTType(mimeType: contentType) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

struct AttachmentChip: View {
    @Environment(ChatSessionModel.self) private var session

    static let defaultPreviewLimit = CGSize(width: 320, height: 240)

    let attachment: AttachmentDisplay
    /// Decides which edge the preview and the file row hang from, so an attachment
    /// lines up with the bubble above it instead of drifting into the transcript.
    let isOwn: Bool
    var previewLimit: CGSize = Self.defaultPreviewLimit
    @State private var preview: NSImage?
    /// The bytes behind `preview`, kept so the viewer can copy and save the original
    /// file without downloading it a second time.
    @State private var previewData: Data?
    @State private var previewFailed = false
    @State private var isViewerPresented = false
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
            if attachment.isImage {
                imagePreview
            }

            fileRow

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .task(id: attachment.id) { await loadPreview() }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let preview {
            let size = previewSize(of: preview)
            // A Button rather than a tap gesture: the preview is a real control, and
            // this is what puts it in the keyboard and VoiceOver order for free.
            Button {
                isViewerPresented = true
            } label: {
                InlinePicture(image: preview, size: size)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Open \(attachment.displayName)")
            .accessibilityLabel("Open \(attachment.displayName)")
            .sheet(isPresented: $isViewerPresented) {
                ImageViewer(
                    title: attachment.displayName,
                    source: .loaded(
                        preview,
                        data: previewData,
                        contentType: attachment.contentType
                    )
                )
            }
        } else if previewFailed {
            // No permanent spinner: a preview that will never arrive should say so.
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 180, height: 90)
                .overlay {
                    Label("Preview unavailable", systemImage: "photo.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 180, height: 90)
                .overlay { ProgressView().controlSize(.small) }
        }
    }

    /// The picture's own size, scaled down to fit the preview cap — see
    /// ``CoreFoundation/CGSize/scaledToFit(_:)``, which an attached GIF measures itself by
    /// too so that the same picture is the same size whichever route it arrived by.
    private func previewSize(of image: NSImage) -> CGSize {
        image.size.scaledToFit(previewLimit)
    }

    /// Fetches image bytes through the authenticated media endpoint.
    ///
    /// `thumbnailUri` is not usable here. Google documents it as a link for a *human*
    /// in a browser and explicitly tells apps not to fetch it — handing it to
    /// `AsyncImage`, which sends no `Authorization` header, is why image attachments
    /// previously sat on a spinner forever.
    private func loadPreview() async {
        guard attachment.isImage, preview == nil, !previewFailed else { return }
        guard let resource = attachment.dataResourceName else {
            previewFailed = true
            return
        }
        do {
            let data = try await session.downloadAttachment(resourceName: resource)
            if let image = NSImage(data: data) {
                preview = image
                previewData = data
            } else {
                previewFailed = true
            }
        } catch {
            previewFailed = true
        }
    }

    private var fileRow: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.symbol)
                .foregroundStyle(.secondary)
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            if isDownloading {
                ProgressView().controlSize(.small)
            } else if attachment.isDownloadable {
                Button(action: save) {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help("Save to…")
                .accessibilityLabel("Download \(attachment.displayName)")
            } else if let uri = attachment.downloadURI, let url = URL(string: uri) {
                // Drive-hosted attachments have no media resource to fetch; opening
                // the link in a browser is the only route.
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("Open in browser")
                .accessibilityLabel("Open \(attachment.displayName) in browser")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }

    private func save() {
        guard let resource = attachment.dataResourceName,
              let destination = AttachmentSavePanel.destination(
                  named: attachment.displayName,
                  contentType: attachment.contentType
              )
        else { return }

        isDownloading = true
        errorMessage = nil
        Task {
            defer { isDownloading = false }
            do {
                let data = try await session.downloadAttachment(resourceName: resource)
                try data.write(to: destination)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
