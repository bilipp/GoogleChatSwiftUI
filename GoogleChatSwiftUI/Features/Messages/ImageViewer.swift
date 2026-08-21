import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where the viewer gets its bytes from.
enum ImageViewerSource {
    /// Already fetched through the authenticated media endpoint, so the viewer only
    /// has to show what the inline preview already downloaded.
    case loaded(NSImage, data: Data?, contentType: String?)
    /// A public image URL from card content, fetched when the viewer opens.
    case remote(URL)
}

/// Full-size image viewer, shown as a sheet over the transcript.
///
/// Images in a transcript were previously a dead end: the inline preview is capped at
/// 320×240 and the only ways to see more were saving the file or opening a browser.
/// Clicking one now opens it here — zoomable, pannable, and still inside the app.
struct ImageViewer: View {
    let title: String
    let source: ImageViewerSource
    /// Suggested filename for Save…. Falls back to the title.
    var fileName: String?

    @Environment(\.dismiss) private var dismiss

    @State private var image: NSImage?
    @State private var data: Data?
    @State private var contentType: String?
    @State private var loadFailed = false
    @State private var errorMessage: String?
    /// Multiple of the fit-to-window scale, so 1 always means "whole image visible"
    /// regardless of how the sheet has been resized.
    @State private var zoom: CGFloat = 1
    @State private var viewport: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            bottomBar
        }
        // Both a minimum and an ideal, because a sheet settles on its size before the
        // image has loaded: an ideal alone would leave every viewer at the placeholder
        // size it was born with.
        .frame(
            minWidth: idealSize.width, idealWidth: idealSize.width, maxWidth: .infinity,
            minHeight: idealSize.height, idealHeight: idealSize.height, maxHeight: .infinity
        )
        .task { await load() }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var content: some View {
        if let image {
            canvas(image)
        } else if loadFailed {
            ContentUnavailableView(
                "Image unavailable",
                systemImage: "photo.badge.exclamationmark",
                description: errorMessage.map(Text.init)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func canvas(_ image: NSImage) -> some View {
        let displayed = displaySize(image)

        return ScrollView([.horizontal, .vertical]) {
            picture(image)
                .frame(width: displayed.width, height: displayed.height)
                // Centres the image while it is smaller than the viewport, and lets
                // the scroll view take over once zooming pushes it past the edges.
                .frame(minWidth: viewport.width, minHeight: viewport.height)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .background(.background.secondary)
        .gesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in zoom = clamped(zoom * value.magnification, in: image) }
        )
        // The usual macOS shorthand: double-click flips between fit and 1:1.
        .onTapGesture(count: 2) { toggleActualSize(image) }
    }

    /// A GIF plays here regardless of Reduce Motion, unlike the still it may have been
    /// inline: getting to this sheet took a deliberate click on the picture, and what that
    /// click asks for is to see the thing move.
    @ViewBuilder
    private func picture(_ image: NSImage) -> some View {
        if image.isAnimated {
            AnimatedImage(image: image)
                .accessibilityLabel(title)
        } else {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .accessibilityLabel(title)
        }
    }

    private func displaySize(_ image: NSImage) -> CGSize {
        let fit = fittedSize(image)
        let scale = clamped(zoom * pinch, in: image)
        return CGSize(width: fit.width * scale, height: fit.height * scale)
    }

    /// The size at which the whole image fits the viewport. Small images are left at
    /// their own size rather than blown up, which is what "fit" means in Preview too.
    private func fittedSize(_ image: NSImage) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else {
            return size
        }
        let scale = min(viewport.width / size.width, viewport.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Zoom multiple at which one image point maps to one point on screen.
    private func actualScale(_ image: NSImage) -> CGFloat {
        let fit = fittedSize(image)
        guard fit.width > 0 else { return 1 }
        return image.size.width / fit.width
    }

    /// Never below fit — panning around an image smaller than the window is not
    /// useful — and never past 8× fit, or 1:1 for images larger than the window.
    private func clamped(_ value: CGFloat, in image: NSImage) -> CGFloat {
        min(max(value, 1), max(8, actualScale(image)))
    }

    private func toggleActualSize(_ image: NSImage) {
        let actual = actualScale(image)
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = abs(zoom - actual) < 0.01 ? 1 : clamped(actual, in: image)
        }
    }

    /// Four fifths of the window the viewer was opened over. Sizing to the image was the
    /// wrong instinct — the canvas fits and centres whatever it is given — and sizing to
    /// the display made a small app window sprout a near-fullscreen sheet.
    ///
    /// A sheet is key but never main, so `mainWindow` is still the window underneath it.
    private var idealSize: CGSize {
        let host = NSApp.mainWindow?.frame.size
            ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }?.frame.size
            ?? NSScreen.main?.visibleFrame.size
            ?? CGSize(width: 1200, height: 800)
        return CGSize(
            width: max(480, host.width * 0.8),
            height: max(360, host.height * 0.8)
        )
    }

    // MARK: - Controls

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            if let errorMessage, image != nil {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let image {
                zoomControls(image)
                Divider().frame(height: 16)
                Button("Copy", systemImage: "doc.on.doc") { copy(image) }
                    .labelStyle(.iconOnly)
                    .help("Copy image")
                Button("Save…", systemImage: "arrow.down.circle") { save() }
                    .labelStyle(.iconOnly)
                    .help("Save to…")
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func zoomControls(_ image: NSImage) -> some View {
        HStack(spacing: 6) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                zoom = clamped(zoom / 1.5, in: image)
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= 1)

            Text(zoomLabel(image))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46)

            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                zoom = clamped(zoom * 1.5, in: image)
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("+", modifiers: .command)
            .disabled(zoom >= max(8, actualScale(image)) - 0.01)

            Button("Actual Size", systemImage: "1.magnifyingglass") {
                toggleActualSize(image)
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("0", modifiers: .command)
            .help("Toggle actual size")
        }
    }

    /// Percentage of the image's own size, which is what the number means everywhere
    /// else on the Mac — not a percentage of the arbitrary fit scale.
    private func zoomLabel(_ image: NSImage) -> String {
        let actual = actualScale(image)
        guard actual > 0 else { return "100%" }
        return "\(Int((zoom / actual * 100).rounded()))%"
    }

    // MARK: - Actions

    private func load() async {
        switch source {
        case .loaded(let image, let data, let contentType):
            self.image = image
            self.data = data
            self.contentType = contentType
        case .remote(let url):
            do {
                let (bytes, response) = try await URLSession.shared.data(from: url)
                guard let loaded = NSImage(data: bytes) else {
                    loadFailed = true
                    return
                }
                image = loaded
                data = bytes
                contentType = response.mimeType
            } catch {
                errorMessage = error.localizedDescription
                loadFailed = true
            }
        }
    }

    /// Copies the original bytes for an animated GIF and the image itself otherwise.
    ///
    /// `writeObjects([image])` puts a TIFF on the pasteboard, which is one flattened frame:
    /// pasting a GIF copied that way into a document or back into Chat would hand over a
    /// still. The encoded bytes paste as the GIF that was copied.
    private func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        if image.isAnimated, let data {
            NSPasteboard.general.setData(data, forType: .init(UTType.gif.identifier))
        } else {
            NSPasteboard.general.writeObjects([image])
        }
    }

    /// Writes the original bytes when we have them; re-encoding a PNG as TIFF just to
    /// save it would hand the user a different file than the one they were sent.
    private func save() {
        guard let destination = AttachmentSavePanel.destination(
            named: fileName ?? title,
            contentType: contentType
        ) else { return }

        do {
            if let data {
                try data.write(to: destination)
            } else if let tiff = image?.tiffRepresentation {
                try tiff.write(to: destination)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
