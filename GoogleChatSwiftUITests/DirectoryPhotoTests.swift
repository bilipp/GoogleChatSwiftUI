import Foundation
import Testing

@testable import GoogleChatSwiftUI

/// Choosing which of a person's photos is their face.
///
/// `people:batchGet` reads from two sources at once — the caller's own Google Contacts
/// and the directory profile — and returns a photo entry for each that has one. So the
/// array is not a list of a person's photos in preference order; it is one answer per
/// source, and the caller has to say which source it meant. A contact entry is Google's
/// grey silhouette whenever the caller never saved a picture for that colleague, which is
/// the normal case, and it is flagged `default` to say so.
///
/// The bug these cover: taking `photos.first` put that silhouette over the initials for
/// precisely the colleagues who happened to be in the reader's contacts, while everyone
/// else in the same workspace showed their real face. It looked like a few accounts had
/// no photo set, and they all did.
struct DirectoryPhotoTests {
    private func photos(_ json: String) throws -> [DirectoryService.BatchGetResponse.Person.Photo] {
        try JSONDecoder().decode(
            [DirectoryService.BatchGetResponse.Person.Photo].self,
            from: Data(json.utf8)
        )
    }

    /// The shape that caused the bug: the placeholder arrives first.
    @Test func prefersTheProfilePhotoOverAContactPlaceholder() throws {
        let parsed = try photos("""
        [
          {
            "url": "https://lh3.googleusercontent.com/a-/PLACEHOLDER=s100",
            "default": true,
            "metadata": { "source": { "type": "CONTACT" } }
          },
          {
            "url": "https://lh3.googleusercontent.com/a-/REAL=s100",
            "metadata": { "source": { "type": "PROFILE" } }
          }
        ]
        """)

        #expect(
            DirectoryService.profilePhotoURL(from: parsed)
                == "https://lh3.googleusercontent.com/a-/REAL=s100"
        )
    }

    /// A workspace colleague's photo can be reported against the domain profile rather
    /// than a personal one. Same meaning, different source name.
    @Test func acceptsADomainProfilePhoto() throws {
        let parsed = try photos("""
        [
          {
            "url": "https://lh3.googleusercontent.com/a-/DOMAIN=s100",
            "metadata": { "source": { "type": "DOMAIN_PROFILE" } }
          }
        ]
        """)

        #expect(
            DirectoryService.profilePhotoURL(from: parsed)
                == "https://lh3.googleusercontent.com/a-/DOMAIN=s100"
        )
    }

    /// Nil rather than the silhouette. Someone with no photo anywhere should reach
    /// ``Avatar`` as having none, so it draws their initials — which identify them —
    /// instead of a grey outline that identifies nobody.
    @Test func reportsNoPhotoWhenEveryEntryIsAPlaceholder() throws {
        let parsed = try photos("""
        [
          {
            "url": "https://lh3.googleusercontent.com/a-/PLACEHOLDER=s100",
            "default": true,
            "metadata": { "source": { "type": "CONTACT" } }
          },
          {
            "url": "https://lh3.googleusercontent.com/a/PLACEHOLDER2=s100",
            "default": true,
            "metadata": { "source": { "type": "PROFILE" } }
          }
        ]
        """)

        #expect(DirectoryService.profilePhotoURL(from: parsed) == nil)
    }

    /// The common case, and the one that was never broken: a single real photo, taken
    /// whether or not the API says where it came from.
    @Test func takesALoneRealPhotoWithoutASource() throws {
        let parsed = try photos("""
        [{ "url": "https://lh3.googleusercontent.com/a/REAL=s100" }]
        """)

        #expect(
            DirectoryService.profilePhotoURL(from: parsed)
                == "https://lh3.googleusercontent.com/a/REAL=s100"
        )
    }

    /// A contact photo the reader actually saved is still a face, and better than
    /// initials. Only `default` disqualifies an entry — the source only ranks it.
    @Test func fallsBackToARealContactPhoto() throws {
        let parsed = try photos("""
        [{
          "url": "https://lh3.googleusercontent.com/contacts/SAVED=s100",
          "metadata": { "source": { "type": "CONTACT" } }
        }]
        """)

        #expect(
            DirectoryService.profilePhotoURL(from: parsed)
                == "https://lh3.googleusercontent.com/contacts/SAVED=s100"
        )
    }

    @Test func reportsNoPhotoWhenThereAreNone() {
        #expect(DirectoryService.profilePhotoURL(from: nil) == nil)
        #expect(DirectoryService.profilePhotoURL(from: []) == nil)
    }
}
