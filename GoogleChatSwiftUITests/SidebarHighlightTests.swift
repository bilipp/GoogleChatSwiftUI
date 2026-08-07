import Testing

@testable import GoogleChatSwiftUI

/// The arrow keys are the only way to reach a search result without the mouse, so
/// the ends of the list and a highlight the query has filtered away have to behave.
struct SidebarHighlightTests {
    private let names = ["spaces/A", "spaces/B", "spaces/C"]

    @Test func firstPressEntersFromTheEndTheKeyPointsAwayFrom() {
        #expect(SidebarHighlight.moved(from: nil, by: 1, in: names) == "spaces/A")
        #expect(SidebarHighlight.moved(from: nil, by: -1, in: names) == "spaces/C")
    }

    @Test func arrowsStepOneRowAtATime() {
        #expect(SidebarHighlight.moved(from: "spaces/A", by: 1, in: names) == "spaces/B")
        #expect(SidebarHighlight.moved(from: "spaces/B", by: -1, in: names) == "spaces/A")
    }

    /// Clamping, not wrapping: a press at the bottom that jumped to the top would
    /// read as the highlight having been lost.
    @Test func theEndsHoldRatherThanWrap() {
        #expect(SidebarHighlight.moved(from: "spaces/C", by: 1, in: names) == "spaces/C")
        #expect(SidebarHighlight.moved(from: "spaces/A", by: -1, in: names) == "spaces/A")
    }

    /// Typing another character can filter away the row the highlight was on. It has
    /// to land somewhere real rather than leaving Return pointing at a hidden row.
    @Test func aHighlightOnAFilteredAwayRowRejoinsTheList() {
        #expect(SidebarHighlight.moved(from: "spaces/Z", by: 1, in: names) == "spaces/A")
        #expect(SidebarHighlight.moved(from: "spaces/Z", by: -1, in: names) == "spaces/C")
    }

    @Test func noResultsMeansNoHighlight() {
        #expect(SidebarHighlight.moved(from: nil, by: 1, in: []) == nil)
        #expect(SidebarHighlight.moved(from: "spaces/A", by: 1, in: []) == nil)
    }
}
