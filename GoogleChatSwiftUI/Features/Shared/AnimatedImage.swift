import AppKit
import SwiftUI

/// An animated image, drawn as one.
///
/// SwiftUI's `Image` takes a snapshot: hand it an `NSImage` decoded from GIF bytes and it
/// draws whichever frame happens to be current and never advances it, which is why every
/// GIF in the transcript used to sit there as a still. AppKit has always animated these —
/// `NSImageView` reads the frame count and the per-frame delays out of the image's own
/// bitmap representation — so this is a wrapper around the view that already knows how,
/// rather than a timer re-implementing the timing on top of `Image`.
///
/// Takes the frame the SwiftUI layout gives it, and scales the picture proportionally
/// inside it.
struct AnimatedImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = AnimatingImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageFrameStyle = .none
        view.isEditable = false
        view.animates = true
        view.image = image
        // Without this the view insists on the picture's own size, and a 498-point-wide
        // Tenor GIF refuses to be drawn in the 320 points the transcript offered it.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        // Identity, not equality: an `NSImage` is a reference type and comparing two of
        // them by value would decode both. A reused view being handed a different image
        // means a different message's GIF, and that is the only case worth reacting to.
        if view.image !== image {
            view.image = image
            view.animates = true
        }
    }
}

/// An image view that is not in the way.
///
/// A GIF in the transcript sits inside a `Button` — the preview is a real control, which is
/// what puts it in the keyboard and VoiceOver order — and an `NSView` inside a SwiftUI
/// button label answers the hit test itself, swallowing the click before SwiftUI sees it.
/// Declining to be hit leaves the picture purely something to look at and the button
/// clickable, which is what both of them are for.
private final class AnimatingImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A picture in the transcript: an image attachment's preview, or a GIF from Chat's picker.
///
/// One view for both because they are the same thing on screen and arrive by completely
/// different routes — one is uploaded bytes fetched through the authenticated media
/// endpoint, the other a public URL on Google's CDN — and neither caller should have to
/// know whether what it is holding moves.
struct InlinePicture: View {
    let image: NSImage
    /// The frame to draw in, already fitted by the caller — see
    /// ``CoreFoundation/CGSize/scaledToFit(_:)``.
    let size: CGSize
    var cornerRadius: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether this is a GIF that is being held still because the reader asked for less
    /// motion. Distinct from a plain still, which needs no explaining.
    private var isPaused: Bool { image.isAnimated && reduceMotion }

    var body: some View {
        picture
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: cornerRadius))
            // Only while paused. A badge over a GIF that is visibly playing labels
            // something the reader can already see; over one that is not, it is the only
            // thing saying there is motion here to go and get.
            .overlay(alignment: .bottomLeading) {
                if isPaused { pausedBadge }
            }
    }

    @ViewBuilder
    private var picture: some View {
        if image.isAnimated, !reduceMotion {
            AnimatedImage(image: image)
        } else {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        }
    }

    private var pausedBadge: some View {
        Label("GIF", systemImage: "play.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: .capsule)
            .padding(4)
            // The whole picture is one button already, and reading its label twice over
            // is not extra information.
            .accessibilityHidden(true)
    }
}

extension NSImage {
    /// Whether this image has more than one frame, and so something to play.
    ///
    /// Asked of the image rather than inferred from the MIME type, which lies in both
    /// directions: plenty of `image/gif` files are a single frame, and an animated one can
    /// arrive under a type nobody thought to check for. The frame count is what decides
    /// whether ``AnimatedImage`` has any work to do.
    var isAnimated: Bool {
        guard let bitmap = representations.first as? NSBitmapImageRep,
              let frames = bitmap.value(forProperty: .frameCount) as? Int
        else { return false }
        return frames > 1
    }
}

nonisolated extension CGSize {
    /// This size scaled down to fit inside `limit`, keeping its proportions.
    ///
    /// Never scaled up: blowing a small picture out to fill the cap only makes it blurry,
    /// which is what "fit" means in Preview too. A degenerate size — an image that failed
    /// to report one — falls back to the limit, since a zero-sized frame draws nothing at
    /// all.
    ///
    /// Shared rather than repeated per call site because a flexible `maxWidth` frame is
    /// the tempting alternative and the wrong one: it claims the full cap and centres the
    /// picture inside it, which left portrait images floating in the middle of the
    /// transcript instead of sitting against their sender's edge.
    func scaledToFit(_ limit: CGSize) -> CGSize {
        guard width > 0, height > 0 else { return limit }
        let scale = min(limit.width / width, limit.height / height, 1)
        return CGSize(width: width * scale, height: height * scale)
    }
}
