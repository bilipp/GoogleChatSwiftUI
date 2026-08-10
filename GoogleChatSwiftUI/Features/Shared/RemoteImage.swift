import AppKit
import SwiftUI

/// An image from a URL, decoded once and shared by every view that shows it.
///
/// `AsyncImage` is the obvious thing to reach for and the wrong one here. It restarts its
/// load whenever the view's identity changes, and a sidebar of 762 conversations, a
/// transcript, a thread list and a search result are all drawing the same few hundred
/// faces at 28 points — so scrolling meant going back to `URLCache` and, worse, decoding
/// the same 96-point JPEG again, on the main thread, for a face that was on screen a
/// moment ago.
///
/// One `NSCache` of decoded images behind all of them instead. Nothing else about
/// `AsyncImage` is missed: there is no placeholder here because the caller already draws
/// one — an avatar shows initials underneath, which is what a person without a photo gets
/// permanently anyway.
struct RemoteImage: View {
    let url: URL

    @State private var image: Image?

    var body: some View {
        // No transition: these land on top of initials that are already the right shape
        // and colour, and a fade would draw the eye to a swap nobody needs to notice.
        Group {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        // Keyed on the URL so a row reused for a different person loads that person's
        // face rather than keeping the last one.
        .task(id: url) { image = await ImageLoader.shared.image(for: url) }
    }
}

/// Fetches and decodes remote images, once each.
///
/// An actor rather than a main-actor cache: decoding is the expensive half and it has no
/// business happening on the thread that is trying to scroll. `NSCache` is what evicts
/// under memory pressure, which a plain dictionary would not.
private actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, NSImage>()
    /// Downloads already in flight, so ten rows asking for the same face at once make
    /// one request between them rather than ten.
    ///
    /// Carries bytes rather than the decoded image: a `Task`'s result has to be
    /// `Sendable` and `NSImage` is not, so the decode happens back here — still off the
    /// main thread, which is the point.
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    init() {
        // Faces at 28 points, of which there are a few hundred in a workspace. Generous
        // enough that scrolling never re-decodes, small enough to be no one's problem.
        cache.countLimit = 400
    }

    func image(for url: URL) async -> Image? {
        if let hit = cache.object(forKey: url as NSURL) { return Image(nsImage: hit) }

        let download = inFlight[url] ?? {
            let started = Task<Data?, Never> {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400
                else { return nil }
                return data
            }
            inFlight[url] = started
            return started
        }()

        let data = await download.value
        inFlight[url] = nil

        // Whoever waited alongside us may have decoded it already while this call was
        // suspended, and one decode is enough.
        if let hit = cache.object(forKey: url as NSURL) { return Image(nsImage: hit) }
        guard let data, let decoded = NSImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: url as NSURL)
        return Image(nsImage: decoded)
    }
}
