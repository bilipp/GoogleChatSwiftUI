import Foundation

/// Where the sidebar's keyboard highlight lands when the arrow keys move it.
///
/// Split out of the view so the cases that are awkward to reach by hand — an empty
/// result list, a highlight on a row the query has since filtered away, either end
/// of the list — are testable.
enum SidebarHighlight {
    /// The row `delta` steps from `current` in the order the sidebar lists them.
    ///
    /// Clamps at both ends rather than wrapping. The list runs to hundreds of rows,
    /// so a press at the top that landed at the very bottom would read as the
    /// highlight having been lost rather than moved.
    /// `nonisolated` because it is pure: the target defaults to `@MainActor`, which
    /// would otherwise put this arithmetic out of reach of the test suite.
    nonisolated static func moved(
        from current: String?,
        by delta: Int,
        in names: [String]
    ) -> String? {
        guard !names.isEmpty else { return nil }
        // No highlight yet, or one whose row is no longer listed: enter the list
        // from the end the key is pointing away from.
        guard let current, let index = names.firstIndex(of: current) else {
            return delta > 0 ? names.first : names.last
        }
        let target = index + delta
        guard names.indices.contains(target) else { return current }
        return names[target]
    }
}
