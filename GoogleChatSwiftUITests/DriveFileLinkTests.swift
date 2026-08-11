import Foundation
import Testing

@testable import GoogleChatSwiftUI

/// Which Drive URLs yield a file ID, and which are correctly left alone.
///
/// These exist because Chat does not annotate every Drive link it carries — a link pasted
/// into a space can arrive as plain text — and the ID then has to come out of the URL.
/// Drive has several URL shapes and they do not put the ID in the same place, so the
/// mistake to guard against is a matcher that reads `edit` or `folders` as an ID and
/// spends a request finding out it was not one.
struct DriveFileLinkTests {
    private func id(_ string: String) -> String? {
        DriveFileLinkParser.fileID(from: URL(string: string)!)
    }

    // MARK: - The `/d/` shape

    @Test("Editor URLs yield the ID after /d/", arguments: [
        "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit",
        "https://docs.google.com/spreadsheets/d/1AbCdEfGhIjKlMnOpQrStUv/edit#gid=0",
        "https://docs.google.com/presentation/d/1AbCdEfGhIjKlMnOpQrStUv/edit#slide=id.p",
        "https://docs.google.com/forms/d/1AbCdEfGhIjKlMnOpQrStUv/viewform",
        "https://docs.google.com/drawings/d/1AbCdEfGhIjKlMnOpQrStUv/edit",
        "https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUv/view?usp=sharing",
    ])
    func editorURLs(_ url: String) {
        #expect(id(url) == "1AbCdEfGhIjKlMnOpQrStUv")
    }

    /// Drive inserts an account index into URLs copied from a browser signed in to more
    /// than one account, which is why the matcher scans for `/d/` instead of indexing a
    /// fixed segment.
    @Test func accountPrefixedURL() {
        #expect(
            id("https://docs.google.com/u/1/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit")
                == "1AbCdEfGhIjKlMnOpQrStUv"
        )
    }

    /// A bare `/d/` under something that is not a Drive file kind is not a file link.
    @Test func unknownKindWithDSegment() {
        #expect(id("https://docs.google.com/gibberish/d/1AbCdEfGhIjKlMnOpQrStUv/edit") == nil)
    }

    // MARK: - Other shapes

    @Test func folderURL() {
        #expect(
            id("https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUv")
                == "1AbCdEfGhIjKlMnOpQrStUv"
        )
    }

    @Test("Legacy id= links still resolve", arguments: [
        "https://drive.google.com/open?id=1AbCdEfGhIjKlMnOpQrStUv",
        "https://drive.google.com/uc?export=download&id=1AbCdEfGhIjKlMnOpQrStUv",
    ])
    func legacyQueryURLs(_ url: String) {
        #expect(id(url) == "1AbCdEfGhIjKlMnOpQrStUv")
    }

    // MARK: - Non-files

    /// Google URLs that are not a file: previewing these would mean a request per
    /// redraw for something that can never resolve.
    @Test("Drive URLs that name no file yield nothing", arguments: [
        "https://drive.google.com/drive/my-drive",
        "https://drive.google.com/drive/shared-with-me",
        "https://drive.google.com/drive/search?q=budget",
        "https://docs.google.com/spreadsheets/u/0/",
    ])
    func nonFileDriveURLs(_ url: String) {
        #expect(id(url) == nil)
    }

    @Test("Non-Drive hosts are ignored", arguments: [
        "https://example.com/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit",
        "https://chat.google.com/room/AAQA1234/xyz",
        "https://calendar.google.com/calendar/u/0/r/eventedit/1AbCdEfGhIjKlMnOpQ",
        // A lookalike host: the check is on the full host, not a suffix, so this must
        // not pass for `drive.google.com`.
        "https://drive.google.com.evil.example/file/d/1AbCdEfGhIjKlMnOpQrStUv/view",
    ])
    func nonDriveHosts(_ url: String) {
        #expect(id(url) == nil)
    }

    /// The `edit`/`view` verbs sit exactly where an ID sits in other shapes, so a length
    /// floor is what keeps them out.
    @Test func shortSegmentsAreNotIDs() {
        #expect(id("https://drive.google.com/drive/folders/edit") == nil)
        #expect(id("https://drive.google.com/open?id=x") == nil)
    }

    // MARK: - Finding links in message text

    @Test func findsLinkInSurroundingProse() {
        let links = DriveFileLinkParser.links(
            in: "notes are in https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit ok?"
        )
        #expect(links.map(\.fileID) == ["1AbCdEfGhIjKlMnOpQrStUv"])
    }

    /// The URL is kept as written rather than rebuilt from the ID, so a link to a
    /// particular sheet tab still opens on that tab.
    @Test func preservesFragmentAndQuery() {
        let links = DriveFileLinkParser.links(
            in: "https://docs.google.com/spreadsheets/d/1AbCdEfGhIjKlMnOpQrStUv/edit#gid=42"
        )
        #expect(links.first?.url.fragment == "gid=42")
    }

    @Test func deduplicatesRepeatedFile() {
        let url = "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit"
        #expect(DriveFileLinkParser.links(in: "\(url) and again \(url)").count == 1)
    }

    @Test func keepsDistinctFilesInOrder() {
        let links = DriveFileLinkParser.links(in: """
            https://docs.google.com/document/d/1FirstFileIdAaaaaaaaaa/edit
            https://drive.google.com/file/d/1SecondFileIdBbbbbbbbb/view
            """)
        #expect(links.map(\.fileID) == ["1FirstFileIdAaaaaaaaaa", "1SecondFileIdBbbbbbbbb"])
    }

    @Test func ignoresTextWithoutDriveLinks() {
        #expect(DriveFileLinkParser.links(in: "see https://example.com/report.pdf").isEmpty)
        #expect(DriveFileLinkParser.links(in: "").isEmpty)
    }

    /// A trailing sentence period is not part of the URL. `NSDataDetector` is used
    /// precisely so cases like this do not need hand-written rules.
    @Test func stripsTrailingPunctuation() {
        let links = DriveFileLinkParser.links(
            in: "it is at https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit."
        )
        #expect(links.map(\.fileID) == ["1AbCdEfGhIjKlMnOpQrStUv"])
    }

    // MARK: - Annotated links

    /// Chat usually supplies the file ID outright.
    @Test func annotationFileIDIsPreferred() throws {
        let metadata = try richLink(fileID: "1AnnotatedIdAaaaaaaaa", uri: nil)
        #expect(DriveFileLinkParser.fileID(of: metadata) == "1AnnotatedIdAaaaaaaaa")
    }

    /// `driveDataRef` is optional in the API and empty on some annotations, so a Drive
    /// link Chat itself recognised must not be given up on for want of that field.
    @Test func annotationFallsBackToParsingURI() throws {
        let metadata = try richLink(
            fileID: nil,
            uri: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit"
        )
        #expect(DriveFileLinkParser.fileID(of: metadata) == "1AbCdEfGhIjKlMnOpQrStUv")
    }

    @Test func annotationWithNeitherYieldsNothing() throws {
        #expect(try DriveFileLinkParser.fileID(of: richLink(fileID: nil, uri: nil)) == nil)
    }

    /// Decoded rather than built with the memberwise initialiser, so these stay valid as
    /// the DTO gains fields.
    private func richLink(fileID: String?, uri: String?) throws -> RichLinkMetadata {
        var json: [String: Any] = ["richLinkType": "DRIVE_FILE"]
        if let uri { json["uri"] = uri }
        if let fileID {
            json["driveLinkData"] = ["driveDataRef": ["driveFileId": fileID]]
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(RichLinkMetadata.self, from: data)
    }
}
