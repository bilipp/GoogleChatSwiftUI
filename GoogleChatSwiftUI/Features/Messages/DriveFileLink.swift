import Foundation

/// A Drive file referenced from a message, and where the reference came from.
///
/// Two things produce these. Chat annotates most Drive URLs it recognises, and those
/// annotations carry the file ID outright. The rest arrive as plain text — a link
/// pasted into a space Chat did not annotate, or one it declined to — and for those the
/// ID has to come out of the URL path.
nonisolated struct DriveFileLink: Sendable, Hashable {
    let fileID: String
    /// The URL to open. Preserved as written rather than rebuilt from the ID, so a link
    /// to a particular tab, slide, or cell range still lands there.
    let url: URL
}

/// Pulls Drive file IDs out of URLs.
///
/// Drive has accumulated a fair number of URL shapes over the years and they do not
/// share a single position for the ID, so each is matched on its own terms:
///
/// - `docs.google.com/document/d/{id}/edit` — also `spreadsheets`, `presentation`,
///   `forms`, `drawings`; the ID follows a `/d/` segment.
/// - `drive.google.com/file/d/{id}/view` — same `/d/` shape for uploaded files.
/// - `drive.google.com/drive/folders/{id}` — folders put it last.
/// - `drive.google.com/open?id={id}` — the old share links, and `uc?id=` downloads.
///
/// A hand-rolled matcher rather than a regex because the shapes differ by segment
/// position rather than by character pattern, and `URLComponents` already did the
/// tokenising.
nonisolated enum DriveFileLinkParser {
    private static let driveHosts: Set<String> = [
        "drive.google.com",
        "docs.google.com",
    ]

    /// The `/d/{id}` shape's own path segments, so `/d/` is only honoured where Drive
    /// actually uses it.
    private static let documentKinds: Set<String> = [
        "document", "spreadsheets", "presentation", "forms", "drawings", "file",
    ]

    /// The file ID a Drive URL names, or nil for a Google URL that is not a file —
    /// a Drive search, someone's My Drive root, a Docs template gallery.
    static func fileID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), driveHosts.contains(host) else { return nil }

        let segments = url.pathComponents.filter { $0 != "/" }

        // `/{kind}/d/{id}` — the modern shape for both editors and uploaded files. The
        // `/u/0/` account prefix Drive sometimes inserts is why this scans for `d`
        // rather than indexing a fixed position.
        if let marker = segments.firstIndex(of: "d"),
           marker > 0,
           documentKinds.contains(segments[marker - 1]),
           let id = segments[safe: marker + 1],
           isPlausibleID(id) {
            return id
        }

        // `/drive/folders/{id}`, with the ID last.
        if let marker = segments.firstIndex(of: "folders"),
           let id = segments[safe: marker + 1],
           isPlausibleID(id) {
            return id
        }

        // `open?id=`, `uc?id=` — the pre-2014 share and download links, still in
        // circulation and still resolvable.
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let id = query.first(where: { $0.name == "id" })?.value,
           isPlausibleID(id) {
            return id
        }

        return nil
    }

    /// The file a Chat rich-link annotation refers to.
    ///
    /// Chat usually supplies the ID outright in `driveDataRef`, but not always — the
    /// field is optional in the API and empty on some annotations — so the URI is parsed
    /// as a fallback rather than giving up on a link Chat itself recognised as Drive.
    static func fileID(of metadata: RichLinkMetadata) -> String? {
        if let id = metadata.driveLinkData?.driveDataRef?.driveFileId, !id.isEmpty {
            return id
        }
        return metadata.uri.flatMap(URL.init(string:)).flatMap(fileID(from:))
    }

    /// Every Drive link in a run of message text, in the order they appear and with
    /// each file kept once.
    ///
    /// Uses the same `NSDataDetector` approach as ``ChatTextRenderer`` for the same
    /// reason: the awkward cases are trailing punctuation and parenthesised URLs, and
    /// hand-rolled patterns get those wrong.
    static func links(in text: String) -> [DriveFileLink] {
        guard !text.isEmpty, let detector else { return [] }

        var found: [DriveFileLink] = []
        var seen: Set<String> = []

        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url,
                  let id = fileID(from: url),
                  seen.insert(id).inserted
            else { continue }
            found.append(DriveFileLink(fileID: id, url: url))
        }
        return found
    }

    /// Built once, like the renderer's: `NSDataDetector` compiles a regex on init and
    /// this runs per message body.
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Rejects path segments that are clearly not IDs before a request is spent on
    /// them. Drive IDs are opaque base64url-ish strings of 20-plus characters; the
    /// things that turn up in the same position and are not IDs — `edit`, `view`,
    /// `folders`, `u` — are short words.
    ///
    /// Deliberately loose. A false positive costs one 404 that is cached; a false
    /// negative silently drops a preview the user asked for.
    private static func isPlausibleID(_ candidate: String) -> Bool {
        candidate.count >= 12 && candidate.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}

nonisolated extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
