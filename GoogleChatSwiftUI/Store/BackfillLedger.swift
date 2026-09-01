import Foundation

/// Which of the one-off local passes over the whole cache have already been run, and
/// under which rules.
///
/// Two passes exist to fill in columns that rows cached by an older build do not have:
/// ``ChatStore/backfillSearchIndex()`` and ``ChatStore/backfillThreads()``. Both are
/// local, both are idempotent, and both were run in full on every launch — which was
/// defensible when they were written and is not any more. `backfillSearchIndex` fetches
/// every cached message to decide it has nothing to write: at 12,596 messages that is a
/// 20MB table materialized into objects on every launch, competing with the fetches the
/// sidebar and the transcript are making at exactly the same moment, to write nothing at
/// all. `backfillThreads` walks every space's messages and threads for the same answer.
///
/// So the answer is remembered instead. The remembered thing is a *version*, not a
/// boolean, which is what keeps the self-healing the original comments were right to
/// want: these passes are written to correct their own output when the formula behind it
/// changes, and bumping the version is what tells them to. It is a deliberate trade — the
/// healing now needs a line changed in ``Pass/version`` rather than happening by itself —
/// and it is the right one, because a formula change is a code change and a launch is not.
///
/// `UserDefaults` rather than the store: this is about whether a pass over the cache has
/// run, so keeping it inside the cache would mean reading the thing being asked about.
/// A store rebuilt after a failed migration takes the answer with it and the passes run
/// again, which is exactly right — the rows they correct went with it too.
nonisolated enum BackfillLedger {
    enum Pass: String, CaseIterable {
        /// ``ChatStore/backfillSearchIndex()``
        case searchIndex
        /// ``ChatStore/backfillThreads()``
        case threadIndex

        /// Bump when the pass would now produce a different answer than it used to —
        /// a change to `CachedMessage.searchIndex(text:fallback:forwarded:)` for the
        /// first, or to how messages are linked to threads for the second. Every
        /// installation then runs that pass once more and stamps the new version.
        var version: Int {
            switch self {
            case .searchIndex: 1
            case .threadIndex: 1
            }
        }

        fileprivate var key: String { "backfill.\(rawValue).version" }
    }

    /// Whether this build's version of the pass has already been run here.
    static func isComplete(_ pass: Pass) -> Bool {
        UserDefaults.standard.integer(forKey: pass.key) >= pass.version
    }

    /// Records the pass as done. Call only on success — a pass that threw has left the
    /// cache half-corrected, and the next launch should finish the job.
    static func markComplete(_ pass: Pass) {
        UserDefaults.standard.set(pass.version, forKey: pass.key)
    }
}
