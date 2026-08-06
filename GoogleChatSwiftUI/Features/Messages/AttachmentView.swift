import SwiftUI
import UniformTypeIdentifiers

/// Attachment chips under a message: image thumbnails inline, everything else as a
/// file row with a download action.
struct AttachmentList: View {
    @Environment(ChatSessionModel.self) private var session

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
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if attachment.isImage, let thumbnail = thumbnailURL {
                AsyncImage(url: thumbnail) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(height: 120)
                        .overlay { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: 320, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 8))
            }

            fileRow

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    /// Thumbnails are served from a Google CDN URL that needs no auth header, unlike
    /// the media endpoint used for the full download.
    private var thumbnailURL: URL? {
        attachment.thumbnailURI.flatMap(URL.init(string:))
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
                Button {
                    save()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help("Save to…")
                .accessibilityLabel("Download \(attachment.displayName)")
            } else if let uri = attachment.downloadURI, let url = URL(string: uri) {
                // Drive-hosted attachments have no media resource to fetch; the only
                // way to open them is in the browser.
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
