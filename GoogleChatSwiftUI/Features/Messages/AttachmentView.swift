import SwiftUI
import UniformTypeIdentifiers

/// Attachment chips under a message: image previews inline, other files as a row
/// with a save action.
struct AttachmentList: View {
    let attachments: [CachedAttachment]
    let isOwn: Bool

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
            ForEach(attachments, id: \.name) { attachment in
                AttachmentChip(attachment: attachment)
            }
        }
    }
}

private struct AttachmentChip: View {
    @Environment(ChatSessionModel.self) private var session

    let attachment: CachedAttachment
    @State private var preview: NSImage?
    @State private var previewFailed = false
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .task(id: attachment.name) { await loadPreview() }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let preview {
            Image(nsImage: preview)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 320, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityLabel(attachment.displayName)
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
        guard let resource = attachment.dataResourceName else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.displayName
        panel.canCreateDirectories = true
        if let type = attachment.contentType, let utType = UTType(mimeType: type) {
            panel.allowedContentTypes = [utType]
        }

        guard panel.runModal() == .OK, let destination = panel.url else { return }

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
