import Foundation
import Observation

/// The directory, held once for the whole window.
///
/// Five views wanted a name and a face for a user ID — the sidebar, the transcript, the
/// thread list, a thread, and search results — and each of them owned an unnarrowed
/// `@Query private var users: [CachedUser]` to get it. That is the most expensive thing
/// left in this app, for two compounding reasons. A `@Query` refetches on *every* write to
/// the store, and none of these could be narrowed: the IDs a view needs are the senders of
/// the messages it just fetched, which a predicate built in `init` cannot know. So each of
/// them materialized the entire `CachedUser` table on the main thread, and with the
/// transcript and its thread inspector both open that was three full directory fetches per
/// save — 18ms each at 1,200 rows, measured, on top of everything else a save already
/// costs. The sync passes save in batches of 25.
///
/// This replaces all five. One fetch, on the store actor rather than the main one, redone
/// only when the directory itself changes — which is a People API answer landing, not any
/// old write. `CachedUser` rows are three fields and a key, so a snapshot of them is
/// small; what was expensive was materializing SwiftData objects, over and over, to read
/// three fields off them.
///
/// Invalidated by notification rather than by the writers telling this directly. Rows are
/// written from several places — title resolution, sender caching, the app-naming sheet,
/// a DM lookup — and a cache that went stale because one of them was overlooked would
/// show a blank avatar until relaunch. The notification cannot be forgotten by a new
/// caller: it is posted by ``ChatStore`` itself, beside the save.
@MainActor
@Observable
final class DirectoryCache {
    /// Every cached profile, by Chat user resource name.
    private(set) var profiles: [String: UserProfile] = [:]

    private let store: ChatStore
    private var watcher: Task<Void, Never>?
    private var pendingReload: Task<Void, Never>?

    init(store: ChatStore) {
        self.store = store
    }

    /// - Parameter userID: a Chat user resource name, e.g. `users/1234567890`. Nil is
    ///   accepted because most callers are reading it off a message, where the sender is
    ///   optional.
    func profile(for userID: String?) -> UserProfile? {
        guard let userID else { return nil }
        return profiles[userID]
    }

    /// Loads the snapshot and keeps it current. Idempotent, so it can be called from
    /// wherever the session is being brought up without coordinating.
    func start() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            await self?.reload()
            for await _ in NotificationCenter.default.notifications(
                named: .chatDirectoryChanged
            ) {
                self?.scheduleReload()
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        pendingReload?.cancel()
        pendingReload = nil
    }

    /// Coalesces a burst of directory writes into one reload.
    ///
    /// A title-resolution pass names 25 spaces from one People call, and the DM lookup
    /// that follows a click writes again immediately. Reloading per notification would
    /// put the cost back that this type exists to remove — just at a lower rate.
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Keeps the previous snapshot on failure. A fetch that fails is not a directory
    /// that emptied, and blanking every name over it would be the worse answer.
    private func reload() async {
        guard let loaded = try? await store.allProfiles() else { return }
        profiles = loaded
    }
}
