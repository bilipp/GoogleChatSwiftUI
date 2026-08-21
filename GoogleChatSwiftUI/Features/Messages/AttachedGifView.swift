import AppKit
import SwiftUI

/// The GIFs a message carries from Chat's own picker, drawn beneath its bubble.
///
/// Outside the bubble for the reason cards are: a GIF *is* the message in almost every
/// case — `text` comes through empty — so there is no prose for it to sit inside, and
/// wrapping it in a coloured bubble reads as two boxes.
struct AttachedGifList: View {
    let uris: [String]
    /// Decides which edge the pictures hang from, so a GIF lines up with its sender's
    /// side of the transcript rather than drifting into the middle.
    let isOwn: Bool
    /// How large a GIF may be drawn. Same cap as an image attachment's preview, so a
    /// picture is the same size whichever of Chat's two routes it arrived by.
    var previewLimit: CGSize = AttachmentChip.defaultPreviewLimit

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
            // Indexed as well as keyed on the URL: nothing stops somebody sending the
            // same GIF twice in one message, and a duplicate id would collapse them.
            ForEach(Array(uris.enumerated()), id: \.offset) { _, uri in
                if let url = URL(string: uri) {
                    AttachedGifView(url: url, previewLimit: previewLimit)
                }
            }
        }
    }
}

/// One GIF, fetched from the public URL Chat gave for it.
///
/// No `Authorization` header, deliberately: these are served from Tenor's CDN rather than
/// from the space, and are the one kind of picture in a transcript that an unauthenticated
/// fetch is correct for. Contrast ``AttachmentChip``, where the same instinct — handing a
/// URL straight to `AsyncImage` — is what left uploaded images on a spinner forever.
struct AttachedGifView: View {
    let url: URL
    var previewLimit: CGSize = AttachmentChip.defaultPreviewLimit

    /// Decoded per view rather than shared from the cache — see ``AnimatedImageData``.
    @State private var image: NSImage?
    /// The bytes behind `image`, kept so the viewer can save and copy the GIF without
    /// fetching it a second time.
    @State private var data: Data?
    @State private var didFail = false
    @State private var isViewerPresented = false

    var body: some View {
        content
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            // A Button rather than a tap gesture: the picture is a real control, and this
            // is what puts it in the keyboard and VoiceOver order for free.
            Button {
                isViewerPresented = true
            } label: {
                InlinePicture(image: image, size: image.size.scaledToFit(previewLimit))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Open GIF")
            .accessibilityLabel("Open GIF")
            .sheet(isPresented: $isViewerPresented) {
                ImageViewer(
                    title: "GIF",
                    source: .loaded(image, data: data, contentType: "image/gif"),
                    fileName: fileName
                )
            }
        } else {
            placeholder
        }
    }

    /// No permanent spinner: a GIF that will never arrive should say so. Reachable in
    /// practice — Chat hands out the CDN link it recorded when the message was posted, and
    /// nothing guarantees it still resolves years later.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .frame(width: 180, height: 90)
            .overlay {
                if didFail {
                    Label("GIF unavailable", systemImage: "photo.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
    }

    /// The last path component, which is what Tenor names these — `lotr-lord-of-the-rings
    /// .gif` for the one that prompted all this. Better than "GIF.gif" in a Save panel,
    /// and there is no other name on offer.
    private var fileName: String {
        let candidate = url.lastPathComponent
        return candidate.hasSuffix(".gif") ? candidate : "GIF.gif"
    }

    private func load() async {
        guard image == nil, !didFail else { return }
        guard let bytes = await AnimatedImageData.shared.data(for: url),
              let decoded = NSImage(data: bytes)
        else {
            didFail = true
            return
        }
        image = decoded
        data = bytes
    }
}

/// Encoded image bytes, fetched once per URL.
///
/// Separate from ``RemoteImage``'s loader, which caches decoded `NSImage`s and hands back a
/// SwiftUI `Image`. That is exactly the wrong currency for a GIF twice over: an `Image` is
/// one frame, and `NSImageView` advances the frame counter *on the `NSImage`*, so two views
/// sharing one cached instance would fight over which frame is current. Caching the bytes
/// instead lets each view decode its own image and animate independently, at the cost of a
/// decode that is cheap next to the download.
private actor AnimatedImageData {
    static let shared = AnimatedImageData()

    private let cache = NSCache<NSURL, NSData>()
    /// Downloads already in flight, so a GIF sent in two conversations at once — or one
    /// whose row is rebuilt mid-fetch while scrolling — makes one request, not several.
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    init() {
        // Costed in bytes rather than counted in entries, unlike the avatar cache: GIFs
        // run from a few kilobytes to several megabytes, so a count limit would either
        // hold far too much or evict a conversation's worth of small ones for no reason.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func data(for url: URL) async -> Data? {
        if let hit = cache.object(forKey: url as NSURL) { return hit as Data }

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

        if let data {
            cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        }
        return data
    }
}
