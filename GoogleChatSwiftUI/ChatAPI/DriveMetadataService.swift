import Foundation
import OSLog

/// What Drive knows about a linked file, reduced to what a preview shows.
nonisolated struct DriveFileMetadata: Sendable, Equatable {
    let fileID: String
    let name: String
    let mimeType: String?
    /// Drive's own file-type icon: a static, unauthenticated URL, so it goes straight to
    /// ``RemoteImage`` with no credentialed path needed.
    let iconURL: URL?
    let modifiedTime: Date?
    let ownerName: String?
    let isTrashed: Bool

    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
}

/// Resolves Drive file IDs to titles and file kinds, once each.
///
/// Chat's own `RichLinkMetadata` cannot do this. It carries a file ID, a MIME type and a
/// URI — no title — because the web client fetches titles from Drive under a separate
/// authorisation, which is exactly what `drive.metadata.readonly` is here for.
///
/// An actor rather than the stateless struct the other services are, because the whole
/// point is to ask once: a transcript can hold the same weekly-status doc twenty times,
/// and a scroll back through history re-renders every chip that was already resolved.
///
/// Failures are cached alongside successes. A link to a file the signed-in user cannot
/// open is ordinary — someone shares a doc into a space that not everyone has access to
/// — and it is a permanent condition for that person, so retrying it on every redraw
/// would spend quota to learn the same 404 repeatedly.
actor DriveMetadataService {
    private let transport: GoogleTransport
    private let logger = AppLog.logger("drive")

    /// Resolved files. Not an `NSCache`: these are a few hundred bytes each and the
    /// count is bounded by how many distinct files a session's transcripts mention.
    private var resolved: [String: DriveFileMetadata] = [:]
    /// IDs known to be unresolvable — no access, deleted, or a scope the grant lacks.
    private var unresolvable: Set<String> = []
    /// In-flight lookups, so twenty chips for one doc make one request between them.
    private var inFlight: [String: Task<DriveFileMetadata?, Never>] = [:]

    init(transport: GoogleTransport) {
        self.transport = transport
    }

    /// Metadata for a file, or nil when it cannot be read. Never throws: a preview that
    /// fails is a chip without a title, not an error the transcript should surface.
    func metadata(for fileID: String) async -> DriveFileMetadata? {
        if let hit = resolved[fileID] { return hit }
        if unresolvable.contains(fileID) { return nil }

        let lookup = inFlight[fileID] ?? {
            let started = Task<DriveFileMetadata?, Never> { await fetch(fileID) }
            inFlight[fileID] = started
            return started
        }()

        let result = await lookup.value
        inFlight[fileID] = nil

        if let result {
            resolved[fileID] = result
        } else {
            unresolvable.insert(fileID)
        }
        return result
    }

    private func fetch(_ fileID: String) async -> DriveFileMetadata? {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(fileID)"
        )!
        components.queryItems = [
            // Requested explicitly because Drive's default field set omits every one of
            // these except the ID.
            URLQueryItem(
                name: "fields",
                value: "id,name,mimeType,iconLink,modifiedTime,trashed,owners(displayName)"
            ),
            // Shared-drive files 404 without this, and a file shared into a Chat space
            // is very often on a shared drive.
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]

        do {
            let file = try await transport.get(components.url!, as: DriveFile.self)
            // A titleless file is not something to render a title-shaped preview around,
            // so it takes the same path as no access at all: the chip keeps its
            // kind-and-URL form.
            guard let name = file.name, !name.isEmpty else { return nil }
            return DriveFileMetadata(
                fileID: file.id ?? fileID,
                name: name,
                mimeType: file.mimeType,
                iconURL: file.iconLink.flatMap(URL.init(string:)),
                modifiedTime: file.modifiedTime,
                ownerName: file.owners?.first?.displayName,
                isTrashed: file.trashed ?? false
            )
        } catch {
            // Debug, not error: the common causes are a file the user cannot open and a
            // grant that predates the Drive scope. Neither is a fault to report.
            logger.debug("No Drive metadata for \(fileID, privacy: .public): \(error)")
            return nil
        }
    }

    private struct DriveFile: Decodable, Sendable {
        struct Owner: Decodable, Sendable { let displayName: String? }
        let id: String?
        let name: String?
        let mimeType: String?
        let iconLink: String?
        let modifiedTime: Date?
        let trashed: Bool?
        let owners: [Owner]?
    }
}
