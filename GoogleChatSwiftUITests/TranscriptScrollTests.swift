import CoreGraphics
import Testing

@testable import GoogleChatSwiftUI

/// A transcript that pulls itself back to the end is right exactly once — when the
/// conversation grew under someone who was already reading the end. Every other time it
/// is taking the scroll view away from the reader.
struct TranscriptScrollTests {
    private func metrics(
        height: Double,
        fromEnd: Double,
        offset: Double = 0
    ) -> TranscriptScrollMetrics {
        TranscriptScrollMetrics(contentHeight: height, distanceFromEnd: fromEnd, offset: offset)
    }

    /// A message arrives, or an attachment finishes loading, beneath a reader sitting at
    /// the end. The offset does not move on its own, so without this they are left
    /// looking at the second-to-last message.
    @Test func growthUnderAReaderAtTheEndFollowsIt() {
        #expect(
            TranscriptScrollMetrics.shouldReturnToEnd(
                from: metrics(height: 1000, fromEnd: 0, offset: 400),
                to: metrics(height: 1200, fromEnd: 200, offset: 400)
            )
        )
    }

    /// The bug this exists to prevent: scrolling up through a thread builds the rows
    /// above as it goes, and each one that lands changes the content height. A reader
    /// who has only just left the end still looks like they are at it.
    @Test func aReaderScrollingUpIsNotDraggedBack() {
        #expect(
            !TranscriptScrollMetrics.shouldReturnToEnd(
                from: metrics(height: 1000, fromEnd: 0, offset: 400),
                to: metrics(height: 1140, fromEnd: 40, offset: 360)
            )
        )
    }

    /// Reading older history is the one thing following must never interrupt.
    @Test func growthAboveAReaderWhoHasScrolledAwayLeavesThemThere() {
        #expect(
            !TranscriptScrollMetrics.shouldReturnToEnd(
                from: metrics(height: 1000, fromEnd: 600, offset: 100),
                to: metrics(height: 1200, fromEnd: 800, offset: 100)
            )
        )
    }

    /// Scrolling on its own changes nothing about the content, and a reader arriving at
    /// the end under their own steam does not need to be sent there.
    @Test func movingWithoutTheContentChangingIsNotFollowed() {
        #expect(
            !TranscriptScrollMetrics.shouldReturnToEnd(
                from: metrics(height: 1000, fromEnd: 300, offset: 100),
                to: metrics(height: 1000, fromEnd: 0, offset: 400)
            )
        )
    }

    /// Sub-pixel layout never leaves the reader exactly at zero, and a couple of points
    /// short of the end is still reading the end.
    @Test func aFewPointsShortOfTheEndStillCountsAsTheEnd() {
        #expect(metrics(height: 1000, fromEnd: 2).isAtEnd)
        #expect(!metrics(height: 1000, fromEnd: 120).isAtEnd)
    }

    /// A conversation shorter than the pane it is in has its end permanently on screen,
    /// which the arithmetic reports as overshooting it.
    @Test func contentShorterThanTheViewIsAlwaysAtTheEnd() {
        #expect(metrics(height: 200, fromEnd: -400).isAtEnd)
    }
}
