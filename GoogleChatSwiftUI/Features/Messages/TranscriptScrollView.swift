import SwiftUI

/// A scroll view that behaves the way a conversation should: it opens on the newest
/// message, keeps following while messages arrive, and stops following the moment the
/// reader scrolls away to read something older.
///
/// Positioning a transcript is not the same problem as positioning a list. A
/// `LazyVStack` knows the height only of the rows it has actually built, so a single
/// command to go to the end is aimed at an estimate — which is how a conversation
/// opens halfway up, and why it lurches again as the real heights arrive. This view
/// converges instead of guessing: it aims at the end, lets the stack build what that
/// revealed, and aims again, keeping the content hidden until the position is real.
/// What the reader sees is a transcript that was simply already at the bottom.
struct TranscriptScrollView<Content: View>: View {
    /// Identity of the newest row. A change means a message was appended.
    let newestID: String?
    /// Identity of the oldest row. A change means history was prepended above.
    let oldestID: String?
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 12
    /// A one-shot jump, e.g. to a search hit. Cleared here once taken.
    var jumpTarget: Binding<String?> = .constant(nil)
    /// The row to hold still while older history loads in above it. Cleared once
    /// restored. Set this *before* asking for more history, not after.
    var historyAnchor: Binding<String?> = .constant(nil)
    /// Bumped by the caller when the reader has done something that means "take me to
    /// the end" — sending a message, above all. Sending is joining the conversation,
    /// so it returns to the end even from halfway up the history.
    var followTrigger: Int = 0
    @ViewBuilder var content: Content

    /// Drives the scroll view's own position commands — the ones that address the end
    /// of the content rather than a particular row.
    @State private var position = ScrollPosition(idType: String.self)
    /// Whether new messages should pull the view down with them.
    @State private var isFollowing = true
    /// False until the opening position is real rather than estimated. The content is
    /// invisible until then, which is the whole point: a jump nobody sees is not a jump.
    @State private var hasSettled = false
    /// A jump that has been requested but not yet landed, so the opening passes aim at
    /// it rather than at the bottom. A search hit is what the reader asked for.
    @State private var pendingJump: String?
    /// True while older history is being held in place. The growth that causes it must
    /// not also be read as "the end moved" — in a conversation short enough to fit on
    /// screen both are true at once, and holding is the one the reader asked for.
    @State private var isHolding = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                    endMarker
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollPosition($position)
            .opacity(hasSettled ? 1 : 0)
            .animation(.easeIn(duration: 0.12), value: hasSettled)
            .task { await settle(proxy) }
            .onChange(of: jumpTarget.wrappedValue, initial: true) { _, target in
                guard let target else { return }
                jumpTarget.wrappedValue = nil
                // Following is not switched off here. Landing away from the end takes
                // the end marker off screen, which switches it off by itself — and a
                // target that turns out not to be in the loaded window leaves the
                // reader at the end, still following, which is where they should be.
                if hasSettled {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                } else {
                    pendingJump = target
                }
            }
            .onChange(of: newestID) { _, id in
                guard hasSettled, isFollowing, id != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    position.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: followTrigger) { _, _ in
                pendingJump = nil
                Task { await returnToEnd() }
            }
            .onChange(of: oldestID) { _, _ in
                guard let anchor = historyAnchor.wrappedValue else { return }
                historyAnchor.wrappedValue = nil
                Task { await hold(anchor, in: proxy) }
            }
            // Rows grow after they are first laid out — an image attachment finishes
            // loading, a link preview resolves. Without this the view keeps its offset
            // and quietly drifts off the end it was sitting on.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                guard hasSettled, isFollowing, !isHolding, new != old else { return }
                position.scrollTo(edge: .bottom)
            }
        }
    }

    /// The end of the transcript, and the definition of "the reader is at the bottom":
    /// whether the end is on screen. That is a question about what is visible, so it
    /// stays correct no matter what the composer or an error banner does to the insets
    /// — which offset arithmetic against a changing safe area does not.
    private var endMarker: some View {
        Color.clear
            .frame(height: 1)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                isFollowing = visible
            }
            .accessibilityHidden(true)
    }

    /// Converges on the opening position, then reveals the transcript.
    ///
    /// Several passes rather than one: each aim builds more of the lazy stack near the
    /// target, which is what makes the next aim more accurate than the last. Two are
    /// normally enough; the rest are insurance for conversations whose rows vary wildly
    /// in height. Cancellation just ends the loop early — the reveal still happens, so
    /// a transcript can never be left invisible.
    private func settle(_ proxy: ScrollViewProxy) async {
        for _ in 0..<4 {
            aim(proxy)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
        }
        pendingJump = nil
        hasSettled = true
    }

    /// Aims at the opening position, whatever it is.
    ///
    /// The end is addressed first even when there is a jump to make, so that a target
    /// which is not in the loaded window falls back to the newest message instead of
    /// leaving the transcript at the top. Both commands go through the proxy in that
    /// case, so the later one deterministically wins.
    private func aim(_ proxy: ScrollViewProxy) {
        // Addressing the last row builds it, which is what corrects the content height
        // that the edge command is measured against.
        if let newestID { proxy.scrollTo(newestID, anchor: .bottom) }
        if let pendingJump {
            proxy.scrollTo(pendingJump, anchor: .center)
        } else {
            position.scrollTo(edge: .bottom)
        }
    }

    /// Returns to the end and holds it there for a moment.
    ///
    /// Sending is not one content change but several spread over a few hundred
    /// milliseconds — the local copy appears, then the server's copy replaces it, then
    /// its final height settles. A single scroll aimed at the first of those lands one
    /// message short of the end, which is the whole complaint.
    private func returnToEnd() async {
        isFollowing = true
        withAnimation(.easeOut(duration: 0.2)) {
            position.scrollTo(edge: .bottom)
        }
        try? await Task.sleep(for: .milliseconds(240))
        for _ in 0..<4 {
            position.scrollTo(edge: .bottom)
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// Keeps a row where it is while older history is inserted above it.
    ///
    /// Unanimated on purpose: nothing moved. The reader stayed still and the
    /// conversation grew downward-from-above underneath them.
    private func hold(_ anchor: String, in proxy: ScrollViewProxy) async {
        isHolding = true
        for _ in 0..<3 {
            proxy.scrollTo(anchor, anchor: .top)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
        }
        isHolding = false
    }
}
