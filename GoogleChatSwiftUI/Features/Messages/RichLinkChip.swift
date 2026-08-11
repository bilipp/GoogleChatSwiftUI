import SwiftUI

/// A smart chip for a Drive file, Calendar event, Meet space, Chat space, or Gmail
/// message that Chat recognised in the message text.
///
/// Drive links resolve to a real title and go to ``DriveLinkChip``. The rest cannot:
/// Chat's `RichLinkMetadata` carries identifiers and a URI but no title, and the web
/// client renders those from Calendar and Gmail APIs it separately authorises for. For
/// those, showing the kind of thing being linked plus a way to open it is what this data
/// actually supports; inventing a title would be worse than omitting one.
struct RichLinkChip: View {
    let link: RichLinkMetadata

    var body: some View {
        if link.richLinkType == "DRIVE_FILE",
           let fileID = DriveFileLinkParser.fileID(of: link) {
            DriveLinkChip(
                fileID: fileID,
                url: link.uri.flatMap(URL.init(string:)),
                mimeTypeHint: link.driveLinkData?.mimeType
            )
        } else {
            LinkChip(
                symbol: symbol,
                tint: tint,
                title: kindLabel,
                subtitle: detail,
                url: link.uri.flatMap(URL.init(string:)),
                accessibilityLabel: "\(kindLabel): \(detail ?? "link")"
            )
        }
    }

    private var symbol: String {
        switch link.richLinkType {
        case "CALENDAR_EVENT": "calendar"
        case "MEET_SPACE": "video"
        case "CHAT_SPACE": "bubble.left.and.bubble.right"
        case "GMAIL_MESSAGE": "envelope"
        default: "link"
        }
    }

    private var tint: Color {
        switch link.richLinkType {
        case "CALENDAR_EVENT": .red
        case "MEET_SPACE": .green
        case "CHAT_SPACE": .purple
        case "GMAIL_MESSAGE": .orange
        default: .secondary
        }
    }

    private var kindLabel: String {
        switch link.richLinkType {
        case "CALENDAR_EVENT": "Calendar event"
        case "MEET_SPACE": meetLabel
        case "CHAT_SPACE": "Chat space"
        case "GMAIL_MESSAGE": "Gmail message"
        default: "Link"
        }
    }

    private var meetLabel: String {
        link.meetSpaceLinkData?.type == "HUDDLE" ? "Huddle" : "Meet call"
    }

    /// The most identifying thing available, falling back to a tidied URL.
    private var detail: String? {
        if let code = link.meetSpaceLinkData?.meetingCode { return code }
        if let uri = link.uri { return LinkChip.tidy(uri) }
        if let event = link.calendarEventLinkData?.eventId { return event }
        return nil
    }
}

/// A Drive link that fills itself in.
///
/// Starts as the kind-and-URL chip a Drive link used to be permanently, then replaces
/// that with the file's actual title, kind, owner and last edit once Drive answers. The
/// arrangement is deliberate: the chip occupies the same height either way, so a
/// transcript does not reflow under the cursor as titles land — the same reason the
/// hover actions in ``MessageBubble`` live in a context menu.
///
/// No thumbnail, and not for want of asking. Drive populates `thumbnailLink` only for
/// apps that can read file content, so a rendered first page would mean holding
/// `drive.readonly` — read access to every file in the account — to decorate a chip.
/// What is here comes from `drive.metadata.readonly`.
struct DriveLinkChip: View {
    let fileID: String
    let url: URL?
    /// Chat's own MIME type for the file, where the link was annotated. Lets the icon
    /// name the right document kind before Drive answers, and stands in if it never does.
    var mimeTypeHint: String?

    @Environment(ChatSessionModel.self) private var session

    @State private var file: DriveFileMetadata?

    var body: some View {
        LinkChip(
            symbol: DriveFileKind.symbol(for: mimeType),
            tint: .blue,
            title: title,
            subtitle: subtitle,
            iconURL: file?.iconURL,
            url: url,
            accessibilityLabel: accessibilityLabel
        )
        // Keyed on the ID so a row reused for a different message resolves that
        // message's file rather than keeping the last one. The service caches, so a
        // re-render of an already-resolved file costs no request.
        .task(id: fileID) { file = await session.driveFile(id: fileID) }
    }

    private var mimeType: String? { file?.mimeType ?? mimeTypeHint }

    private var title: String {
        file?.name ?? DriveFileKind.label(for: mimeType)
    }

    /// Kind, owner and edit date once resolved; the URL until then, which is what the
    /// chip showed before this could resolve anything at all.
    private var subtitle: String? {
        guard let file else { return url.map { LinkChip.tidy($0.absoluteString) } }

        var parts = [DriveFileKind.label(for: file.mimeType)]
        if let owner = file.ownerName { parts.append(owner) }
        if file.isTrashed { parts.append("In trash") }
        if let modified = file.modifiedTime {
            parts.append("Edited \(modified.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        guard let file else { return "Google Drive: \(url?.absoluteString ?? fileID)" }
        return "\(DriveFileKind.label(for: file.mimeType)): \(file.name)"
    }
}

/// Names and icons for Drive MIME types.
///
/// Drive reports Workspace documents under `application/vnd.google-apps.*` and uploads
/// under their real type, so both families are mapped. Anything unrecognised falls back
/// to a generic file rather than showing a raw MIME type to a reader.
nonisolated enum DriveFileKind {
    static func label(for mimeType: String?) -> String {
        guard let mimeType else { return "Google Drive" }
        switch mimeType {
        case "application/vnd.google-apps.document": return "Google Doc"
        case "application/vnd.google-apps.spreadsheet": return "Google Sheet"
        case "application/vnd.google-apps.presentation": return "Google Slides"
        case "application/vnd.google-apps.form": return "Google Form"
        case "application/vnd.google-apps.drawing": return "Google Drawing"
        case "application/vnd.google-apps.script": return "Apps Script"
        case "application/vnd.google-apps.folder": return "Folder"
        case "application/vnd.google-apps.shortcut": return "Shortcut"
        case "application/pdf": return "PDF"
        default: break
        }
        if mimeType.hasPrefix("image/") { return "Image" }
        if mimeType.hasPrefix("video/") { return "Video" }
        if mimeType.hasPrefix("audio/") { return "Audio" }
        if mimeType.contains("spreadsheet") || mimeType.contains("excel") { return "Spreadsheet" }
        if mimeType.contains("presentation") || mimeType.contains("powerpoint") { return "Presentation" }
        if mimeType.contains("word") || mimeType.contains("document") { return "Document" }
        if mimeType.contains("zip") || mimeType.contains("compressed") { return "Archive" }
        return "File"
    }

    /// The fallback icon, used until Drive's own `iconLink` arrives and permanently for
    /// a file that never resolves.
    static func symbol(for mimeType: String?) -> String {
        guard let mimeType else { return "doc" }
        switch label(for: mimeType) {
        case "Google Sheet", "Spreadsheet": return "tablecells"
        case "Google Slides", "Presentation": return "rectangle.on.rectangle"
        case "Google Doc", "Document": return "doc.text"
        case "Folder": return "folder"
        case "Shortcut": return "arrowshape.turn.up.right"
        case "PDF": return "doc.richtext"
        case "Image": return "photo"
        case "Video": return "film"
        case "Audio": return "waveform"
        case "Archive": return "doc.zipper"
        case "Google Form": return "list.bullet.rectangle"
        case "Google Drawing": return "scribble"
        case "Apps Script": return "curlybraces"
        default: return "doc"
        }
    }
}

/// The chip surface every link kind shares: icon, two lines, an open affordance.
///
/// Extracted so a Drive chip that has resolved a title and one that has not are the same
/// view with different text, rather than two layouts that drift apart.
struct LinkChip: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?
    /// Drive's own file-type icon. A static, unauthenticated URL, so it needs no
    /// credentialed fetch — where it is absent, ``symbol`` stands in.
    var iconURL: URL?
    let url: URL?
    let accessibilityLabel: String

    var body: some View {
        Group {
            if let url {
                Link(destination: url) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var content: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if url != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .contentShape(.rect)
    }

    /// Drive's own icon where there is one, an SF Symbol otherwise.
    ///
    /// One or the other, not layered: Drive's icons are PNGs with transparent margins,
    /// and a symbol showing through them reads as a rendering fault. The swap is cheap
    /// to look at because these icons are per file *type*, not per file — the first
    /// Sheet in a session fetches the icon and every Sheet after it finds the decoded
    /// image already in ``RemoteImage``'s cache.
    @ViewBuilder private var icon: some View {
        if let iconURL {
            RemoteImage(url: iconURL)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
        }
    }

    static func tidy(_ uri: String) -> String {
        uri
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}
