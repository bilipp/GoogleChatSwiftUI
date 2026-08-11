import SwiftUI

/// The band drawn behind the message a jump landed on.
///
/// Scrolling to a message does not say which message it was. It puts the thing that was
/// asked for somewhere in a screenful of other messages and leaves the reader to work out
/// which one — and within a run from one sender, at a glance, every candidate looks the
/// same. A link is a promise to show someone a specific message, so the row that was
/// aimed at says that it is the one.
///
/// It flashes before it settles, because what has to be caught is the arrival: the eye
/// notices a movement in a transcript it has not read yet, where it would not notice a
/// colour. And it fades out afterwards rather than staying, because by then the question
/// has been answered — a permanent mark would only become a second kind of selection,
/// competing with the real one and needing to be explained.
private struct MessageHighlight: ViewModifier {
    let isActive: Bool

    /// How strongly the band is drawn: 0 for absent, 1 for settled, and above 1 for the
    /// flash on arrival. One number rather than a set of flags, so the flash, the settle
    /// and the fade are three animations of the same value and cannot contradict
    /// each other.
    @State private var intensity: Double = 0

    func body(content: Content) -> some View {
        content
            .background { MessageHighlightBand(intensity: intensity) }
            .task(id: isActive) { await animate() }
    }

    /// Runs whichever of the two transitions the new state calls for.
    ///
    /// The peak is held for a moment before settling: an animation straight from the peak
    /// to the resting value is a single continuous ramp, which is exactly what the eye
    /// does not catch.
    private func animate() async {
        guard isActive else {
            // Nothing to fade for the rows that were never highlighted, which is nearly
            // all of them.
            guard intensity > 0 else { return }
            withAnimation(.easeOut(duration: 0.45)) { intensity = 0 }
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { intensity = 1.8 }
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.7)) { intensity = 1 }
    }
}

/// What the mark is actually made of, at a given strength.
///
/// A tinted fill and a hairline of the same accent, both scaled by one number: the fill
/// alone reads as a shadow at these opacities and the outline alone as a box drawn around
/// nothing. Separate from the modifier above so the material can be looked at without
/// waiting for the animation that drives it.
struct MessageHighlightBand: View {
    let intensity: Double

    var body: some View {
        // Wider and taller than the row it backs, so it reads as a band the message sits
        // in rather than as a second bubble drawn around the bubble.
        shape
            .fill(Color.accentColor.opacity(0.10 * intensity))
            .overlay { shape.strokeBorder(Color.accentColor.opacity(0.35 * intensity)) }
            .padding(.horizontal, -6)
            .padding(.vertical, -1)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }
}

extension View {
    /// Marks this row as the one a jump was aimed at — see ``MessageHighlight``.
    func messageHighlight(_ isActive: Bool) -> some View {
        modifier(MessageHighlight(isActive: isActive))
    }
}
