import SwiftUI

/// A smart chip for a Drive file, Calendar event, Meet space, Chat space, or Gmail
/// message that Chat recognised in the message text.
///
/// Deliberately not a fetched preview. Chat's `RichLinkMetadata` carries identifiers
/// and a URI but no title, thumbnail, or description — the web client renders those
/// from Drive and Calendar APIs it separately authorises for. Showing the kind of
/// thing being linked, plus a way to open it, is what this data actually supports;
/// inventing a title would be worse than omitting one.
struct RichLinkChip: View {
    let link: RichLinkMetadata

    var body: some View {
        Group {
            if let url = link.uri.flatMap(URL.init(string:)) {
                Link(destination: url) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityLabel("\(kindLabel): \(detail ?? "link")")
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(kindLabel)
                    .font(.caption.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if link.uri != nil {
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

    private var symbol: String {
        switch link.richLinkType {
        case "DRIVE_FILE": driveSymbol
        case "CALENDAR_EVENT": "calendar"
        case "MEET_SPACE": "video"
        case "CHAT_SPACE": "bubble.left.and.bubble.right"
        case "GMAIL_MESSAGE": "envelope"
        default: "link"
        }
    }

    /// Drive links carry a MIME type, so the icon can name the actual document kind
    /// rather than showing a generic file for a spreadsheet.
    private var driveSymbol: String {
        guard let mime = link.driveLinkData?.mimeType else { return "doc" }
        if mime.contains("spreadsheet") { return "tablecells" }
        if mime.contains("presentation") { return "rectangle.on.rectangle" }
        if mime.contains("document") { return "doc.text" }
        if mime.contains("folder") { return "folder" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        return "doc"
    }

    private var tint: Color {
        switch link.richLinkType {
        case "DRIVE_FILE": .blue
        case "CALENDAR_EVENT": .red
        case "MEET_SPACE": .green
        case "CHAT_SPACE": .purple
        case "GMAIL_MESSAGE": .orange
        default: .secondary
        }
    }

    private var kindLabel: String {
        switch link.richLinkType {
        case "DRIVE_FILE": "Google Drive"
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

    /// The most identifying thing available, falling back to a tidied URL. Chat gives
    /// no human-readable title for any of these.
    private var detail: String? {
        if let code = link.meetSpaceLinkData?.meetingCode { return code }
        if let uri = link.uri { return tidy(uri) }
        if let file = link.driveLinkData?.driveDataRef?.driveFileId { return file }
        if let event = link.calendarEventLinkData?.eventId { return event }
        return nil
    }

    private func tidy(_ uri: String) -> String {
        uri
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}
