import SwiftUI

/// One reaction emoji, drawn from its reaction key (see ``ChatEmoji/display``).
///
/// A Unicode emoji is text in the surrounding font. A custom emoji is the
/// organisation's image, sized to the font's line height so it sits in a chip exactly
/// where the character would. One this session has no image for falls back to its
/// shortcode, or a puzzle piece when even that is unknown.
struct ReactionEmoji: View {
    @Environment(ChatSessionModel.self) private var session

    let key: String

    var body: some View {
        if ChatEmoji.customUID(fromKey: key) == nil {
            Text(key)
        } else if let url = session.customEmoji(forKey: key)?.temporaryImageUri.flatMap(URL.init(string:)) {
            // The image is drawn in the current font's em box, so the same view fits
            // a caption-sized chip and a title-sized picker cell.
            Text(verbatim: "\u{2003}")
                .hidden()
                .overlay { RemoteImage(url: url).clipped() }
                .accessibilityLabel(session.emojiLabel(key))
        } else if let name = session.customEmoji(forKey: key)?.emojiName {
            Text(name)
        } else {
            Text("🧩")
        }
    }
}
