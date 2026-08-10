import SwiftUI

/// A scroll view that behaves the way a conversation should: it opens on the newest
/// message, keeps following while messages arrive, stops following the moment the reader
/// scrolls away to read something older, and fetches more of it as they reach the top.
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
    /// True while a page of older history is on its way. Read only to know when a
    /// request this view asked for has finished, so the next one may be asked for.
    var isLoadingOlder: Bool = false
    /// Asks for the page above the transcript, called when the reader reaches the start
    /// of what is loaded. Nil when there is nothing older to fetch — the beginning of a
    /// conversation, or a thread, which is always loaded whole.
    var onReachStart: (() -> Void)?
    @ViewBuilder var content: Content

    /// Drives the scroll view's own position commands — the ones that address the end
    /// of the content rather than a particular row.
    @State private var position = ScrollPosition(idType: String.self)
    /// Whether new messages should pull the view down with them — true while the end of
    /// the transcript is what the reader is looking at. Kept in step with the scroll
    /// geometry below.
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
    /// True while the reader has hold of the scroll view: a drag, a wheel, or the glide
    /// that follows one.
    @State private var isReaderScrolling = false
    /// True once older history has been asked for and not yet delivered, so arriving at
    /// the top asks for one page rather than one per frame of the scroll that got there.
    @State private var hasAskedForOlder = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
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
                // Following is not switched off here. Landing away from the end is a
                // move away from it, which switches it off by itself — and a target
                // that turns out not to be in the loaded window leaves the reader at
                // the end, still following, which is where they should be.
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
            // Where the reader is, and whether the ground moved under them. Rows grow
            // after they are first laid out — an image attachment finishes loading, a
            // link preview resolves — and without a correction the view keeps its offset
            // and quietly drifts off the end it was sitting on.
            //
            // Both answers come from the same reading of the scroll geometry, so they
            // cannot disagree. Asking a marker view at the end of the stack whether it
            // is on screen looks equivalent and is not: its answer arrives a beat after
            // the offset it describes, and the beat is long enough for a correction to
            // undo the scroll the reader just made.
            .onScrollGeometryChange(for: TranscriptScrollMetrics.self) {
                TranscriptScrollMetrics($0)
            } action: { old, new in
                isFollowing = new.isAtEnd
                askForOlderHistoryIfNeeded(at: new)
                guard hasSettled, !isHolding, !isReaderScrolling else { return }
                guard TranscriptScrollMetrics.shouldReturnToEnd(from: old, to: new) else { return }
                position.scrollTo(edge: .bottom)
            }
            // Nothing repositions the transcript while the reader is moving it
            // themselves. Scrolling up builds the rows above as it goes, and every one
            // that lands changes the content height — mistaking that for the transcript
            // growing beneath someone sitting at the end is what makes a short thread
            // impossible to scroll up through at all.
            .onScrollPhaseChange { _, phase in
                isReaderScrolling = phase == .tracking
                    || phase == .interacting
                    || phase == .decelerating
            }
            // A page has landed, or the attempt to fetch one has ended. Either way this
            // view may ask again — and if the reader is still at the top of a
            // conversation shorter than the pane, the growth that just arrived is itself
            // the geometry change that asks.
            .onChange(of: isLoadingOlder) { _, loading in
                if !loading { hasAskedForOlder = false }
            }
        }
    }

    /// Asks for the page above the transcript once the reader comes within reach of its
    /// start, which is what replaces reaching for a button to do the same thing.
    ///
    /// Driven only by scroll geometry, and that is what keeps a failed fetch from
    /// becoming a retry loop: the ask is cleared when the request ends, but nothing asks
    /// again until either the reader or the content actually moves.
    private func askForOlderHistoryIfNeeded(at metrics: TranscriptScrollMetrics) {
        // Not while the opening position is still being converged on: those passes build
        // the stack from the top, so every transcript would look like a reader who had
        // scrolled back to the beginning of it. Nor while history is being held in
        // place — that scroll is the last page arriving, not a request for the next.
        guard hasSettled, !isHolding, !hasAskedForOlder else { return }
        guard let onReachStart, metrics.isNearStart else { return }
        hasAskedForOlder = true
        onReachStart()
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

/// What a scroll view looked like at one moment, reduced to the few facts that decide
/// whether the transcript should be pulled back to its end, and whether it is time to
/// fetch more of its history.
///
/// `nonisolated` because it is pure arithmetic: the target defaults to `@MainActor`,
/// which would otherwise put it out of reach of the test suite.
nonisolated struct TranscriptScrollMetrics: Equatable {
    /// Height of everything in the scroll view.
    var contentHeight: CGFloat
    /// How far the end of the content sits below what the reader can see. Zero when they
    /// are looking at the end, and growing as they scroll away from it. Derived from the
    /// visible rect rather than the raw offset, so it stays honest whatever the composer
    /// or an error banner does to the insets.
    var distanceFromEnd: CGFloat
    /// How far the start of the content sits above what the reader can see — the mirror
    /// of `distanceFromEnd`, and zero when the oldest loaded message is on screen.
    var distanceFromStart: CGFloat
    /// How far down the content the reader is. Only the direction it moves is used.
    var offset: CGFloat

    /// Sub-pixel layout means "at the end" is never exactly zero, and a reader a couple
    /// of points off the end is still reading the end.
    static let endTolerance: CGFloat = 8

    /// How far short of the top counts as reaching it. Generous on purpose: a page takes
    /// a round trip to arrive, and asking for it a screenful early is the difference
    /// between history that is simply there and history that has to be waited for.
    static let startLead: CGFloat = 400

    var isAtEnd: Bool { distanceFromEnd <= Self.endTolerance }

    /// Close enough to the start of the loaded history that the next page should already
    /// be on its way. Negative distances count: rubber-banding past the top is about as
    /// clear a request for more as there is.
    var isNearStart: Bool { distanceFromStart <= Self.startLead }

    init(
        contentHeight: CGFloat,
        distanceFromEnd: CGFloat,
        distanceFromStart: CGFloat,
        offset: CGFloat
    ) {
        self.contentHeight = contentHeight
        self.distanceFromEnd = distanceFromEnd
        self.distanceFromStart = distanceFromStart
        self.offset = offset
    }

    init(_ geometry: ScrollGeometry) {
        self.init(
            contentHeight: geometry.contentSize.height,
            distanceFromEnd: geometry.contentSize.height - geometry.visibleRect.maxY,
            distanceFromStart: geometry.visibleRect.minY,
            offset: geometry.contentOffset.y
        )
    }

    /// Whether the change between two moments is the transcript growing under a reader
    /// who was sitting at its end — the one case that should carry them along with it.
    ///
    /// Judged from where the reader *was*. Reading the new position instead answers the
    /// wrong question: growth pushes the end away from whoever is watching it, so at that
    /// point everybody looks like they have scrolled off. And growth that the reader
    /// moved up into is not growth they should be dragged back down through, however the
    /// two arrived in the same reading.
    static func shouldReturnToEnd(from old: Self, to new: Self) -> Bool {
        guard old.contentHeight != new.contentHeight, old.isAtEnd else { return false }
        return new.offset >= old.offset
    }
}
