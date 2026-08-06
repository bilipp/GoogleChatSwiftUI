import SwiftData
import SwiftUI

/// Sidebar + detail. The sidebar is activity-scoped by default because this account
/// has 762 spaces; search reaches all of them regardless of filter.
struct SpacesListView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(ChatSessionModel.self) private var session
    @Query(sort: [SortDescriptor(\CachedSpace.lastActiveTime, order: .reverse)])
    private var allSpaces: [CachedSpace]
    /// Directory profiles, for DM avatars. Chat supplies no images of its own.
    @Query private var users: [CachedUser]
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var session = session

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if session.isSearchingMessages {
                // Replaces the transcript rather than overlaying it: search results
                // and a conversation are two different things to be reading.
                MessageSearchResults(
                    query: session.messageQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                    scopedTo: session.messageSearchScope == .currentConversation
                        ? session.selectedSpaceName
                        : nil
                )
                // Re-queries when the text or scope changes; without this the fetch
                // descriptor built in `init` would be reused.
                .id("\(session.messageQuery)|\(session.messageSearchScope.rawValue)")
            } else if let selected = selectedSpace {
                MessageListView(
                    spaceName: selected.name,
                    spaceTitle: selected.title,
                    isThreaded: selected.isThreaded
                )
                // Identity tied to the space so switching conversations builds a fresh
                // view. Without it SwiftUI reuses the instance and carries the previous
                // space's scroll offset into the new transcript.
                .id(selected.name)
                .inspector(isPresented: threadBinding) {
                    if let thread = session.selectedThreadName {
                        ThreadPane(spaceName: selected.name, threadName: thread)
                            // Likewise per thread, so reopening a different thread does
                            // not inherit the last one's position.
                            .id(thread)
                            // The inspector's default width is sized for property
                            // panels, not a conversation — bubbles plus an avatar
                            // need real room or they collapse to a few words a line.
                            .inspectorColumnWidth(min: 380, ideal: 460, max: 760)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a space or direct message to read it.")
                )
            }
        }
        // `.searchable` rather than a hand-rolled toolbar field. A TextField hosted
        // in a ToolbarItem cannot be focused programmatically at all — toolbar content
        // lives in a separate hierarchy — so no amount of FocusState plumbing made ⌘F
        // work. SwiftUI's own search field is in the toolbar *and* wires up ⌘F.
        .searchable(
            text: $session.messageQuery,
            placement: .toolbar,
            prompt: "Search messages"
        )
        .searchScopes($session.messageSearchScope, activation: .onTextEntry) {
            ForEach(MessageSearchScope.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ProfileMenu(
                    profile: currentProfile,
                    totalUnread: session.totalUnread,
                    onSignOut: { Task { await auth.signOut() } },
                    onMarkAllRead: { Task { await session.markAllRead() } }
                )
            }
        }
        .task {
            // First, because this is a click that landed before the view existed —
            // the one that launched the app — and the loaders below run in bounded
            // passes that take seconds. The cache is already on disk, so the
            // conversation opens without waiting for any of them.
            await openFromNotification()
            if case .idle = session.spacesState { await session.refreshSpaces() }
            await session.startRealtime()
            await session.prepareSearchIndex()
            await session.loadReadStates()
        }
        // Subsequent clicks, while the app is already running.
        .onChange(of: NotificationRouter.shared.pendingSpaceName) { _, pending in
            guard pending != nil else { return }
            Task { await openFromNotification() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSWorkspace.didWakeNotification
            )
        ) { _ in
            // Pub/Sub retains 24h, so nothing is lost across sleep, but the open
            // space should catch up immediately rather than waiting for the next event.
            Task { await session.reconcileSelectedSpace() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatRefreshSpaces)) { _ in
            Task { await session.refreshSpaces() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatMarkAllRead)) { _ in
            Task { await session.markAllRead() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatFocusSearch)) { _ in
            isSearchFocused = true
        }
    }

    /// Opens the conversation a clicked notification named.
    ///
    /// Relaxes any filter that would hide it. The filters are a browsing preference,
    /// not a reason to refuse an explicit request — and without this the transcript
    /// would open with no matching sidebar row, leaving no sense of where you are.
    private func openFromNotification() async {
        guard let name = NotificationRouter.shared.claimPendingSpace() else { return }

        if let space = allSpaces.first(where: { $0.name == name }) {
            if !session.kind.matches(space) { session.kind = .all }
            if !session.scope.matches(space, now: Date()) { session.scope = .all }
            if space.isMuted { session.showsMuted = true }
            let query = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty, !space.title.localizedCaseInsensitiveContains(query) {
                session.searchText = ""
            }
        }

        await session.revealSpace(name)
    }

    /// The inspector's own dismiss control clears the selected thread, keeping the
    /// model in step with a close the user performed via the window chrome.
    private var threadBinding: Binding<Bool> {
        Binding(
            get: { session.selectedThreadName != nil },
            set: { shown in if !shown { session.openThread(nil) } }
        )
    }

    private var currentProfile: GoogleUserProfile? {
        if case .signedIn(let profile) = auth.state { return profile }
        return nil
    }

    private var selectedSpace: CachedSpace? {
        guard let name = session.selectedSpaceName else { return nil }
        return allSpaces.first { $0.name == name }
    }

    private var sidebar: some View {
        @Bindable var session = session

        return List(selection: Binding(
            get: { session.selectedSpaceName },
            set: { name in
                guard let name else { return }
                Task { await session.openSpace(name) }
            }
        )) {
            ForEach(groupedSpaces, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.spaces) { space in
                        SpaceRow(space: space, peer: peer(for: space))
                            .tag(space.name)
                            .contextMenu { rowMenu(for: space) }
                    }
                    .onMove(perform: moveHandler(for: group))
                }
            }
        }
        // Dissolves rows into the header instead of letting them slide under it.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .overlay { emptyOverlay }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                SidebarSearchField(
                    text: $session.searchText,
                    placeholder: "Search conversations",
                    isFocused: $isSearchFocused
                )
                SidebarFilterBar(
                    scope: $session.scope,
                    kind: $session.kind,
                    showsMuted: $session.showsMuted,
                    scopeCounts: scopeCounts,
                    kindCounts: kindCounts,
                    mutedCount: mutedCount,
                    visibleCount: visibleSpaces.count
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RealtimeStatusBar(
                status: session.realtimeStatus,
                isRefreshing: session.isRefreshingSpaces
            ) {
                Task { await session.refreshSpaces() }
            }
        }
    }

    /// How many rows each scope would show, honouring the current kind — so the
    /// numbers in the menu match what picking that option actually produces.
    private var scopeCounts: [SpaceScope: Int] {
        let now = Date()
        var counts: [SpaceScope: Int] = [:]
        for option in SpaceScope.allCases {
            counts[option] = allSpaces.count { space in
                option.matches(space, now: now) && session.kind.matches(space)
            }
        }
        return counts
    }

    private var kindCounts: [SpaceKind: Int] {
        let now = Date()
        var counts: [SpaceKind: Int] = [:]
        for option in SpaceKind.allCases {
            counts[option] = allSpaces.count { space in
                session.scope.matches(space, now: now) && option.matches(space)
            }
        }
        return counts
    }

    private var usersByID: [String: CachedUser] {
        Dictionary(users.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The single other person in a DM. Group chats intentionally get a tile instead
    /// of one arbitrary member's face.
    private func peer(for space: CachedSpace) -> CachedUser? {
        guard space.spaceType == .directMessage,
              let id = space.peerUserIDs.first
        else { return nil }
        return usersByID[id]
    }

    /// Search overrides the scope — if you're looking for a dormant DM by name,
    /// having "Recent" silently hide it would be actively unhelpful. The kind filter
    /// still applies, since that is a deliberate narrowing rather than a time limit.
    private var visibleSpaces: [CachedSpace] {
        let query = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return allSpaces.filter { space in
                session.kind.matches(space) && space.title.localizedCaseInsensitiveContains(query)
            }
        }
        let now = Date()
        return allSpaces.filter { space in
            guard session.kind.matches(space) else { return false }
            // Pinning outranks both the scope and the muted toggle: it is an explicit
            // "keep this in front of me", and a pin that vanished because the
            // conversation went quiet for a month would be worse than no pin at all.
            if space.isPinned { return true }
            guard session.showsMuted || !space.isMuted else { return false }
            return session.scope.matches(space, now: now)
        }
    }

    /// Pinned rows are counted out: they are listed regardless of this toggle, so
    /// including them would promise rows the toggle cannot actually reveal.
    private var mutedCount: Int {
        let now = Date()
        return allSpaces.count { space in
            space.isMuted && !space.isPinned
                && session.scope.matches(space, now: now) && session.kind.matches(space)
        }
    }

    /// The pinned group in the arrangement the user chose.
    ///
    /// Pinned wins over muted for a space that is both: you can pin something you
    /// have silenced, and the pin is the more deliberate of the two instructions.
    private var pinnedSpaces: [CachedSpace] {
        visibleSpaces
            .filter(\.isPinned)
            // Ties fall back to the query's recency order, so a group pinned before
            // ordering existed still lists in a stable, sensible sequence.
            .sorted { $0.pinnedOrder < $1.pinnedOrder }
    }

    /// Only the pinned group is arrangeable: the others are ordered by the server's
    /// section order and by recency, neither of which is this app's to overrule.
    /// `nil` leaves those rows undraggable.
    ///
    /// Spelled out as a typed closure rather than a ternary inside the list body,
    /// which pushed that expression past what the type checker would solve.
    private func moveHandler(for group: SpaceGroup) -> ((IndexSet, Int) -> Void)? {
        guard group.isPinned else { return nil }
        return { offsets, destination in movePinned(from: offsets, to: destination) }
    }

    /// Drag-to-reorder within the pinned section.
    private func movePinned(from offsets: IndexSet, to destination: Int) {
        var names = pinnedSpaces.map(\.name)
        names.move(fromOffsets: offsets, toOffset: destination)
        Task { await session.reorderPinned(names) }
    }

    /// The same reorder by one step, for the context menu.
    ///
    /// Dragging is the obvious gesture but the worst one to rely on alone here: the
    /// rows are also a selection list, the group can be taller than the sidebar, and
    /// a drag is unreachable by keyboard or VoiceOver.
    private func movePinned(_ space: CachedSpace, by delta: Int) {
        var names = pinnedSpaces.map(\.name)
        guard let index = names.firstIndex(of: space.name),
              names.indices.contains(index + delta)
        else { return }
        names.swapAt(index, index + delta)
        Task { await session.reorderPinned(names) }
    }

    @ViewBuilder
    private func rowMenu(for space: CachedSpace) -> some View {
        Button(space.isPinned ? "Unpin" : "Pin", systemImage: space.isPinned ? "pin.slash" : "pin") {
            Task { await session.setPinned(!space.isPinned, for: space.name) }
        }
        Button(
            space.isMuted ? "Unmute" : "Mute",
            systemImage: space.isMuted ? "bell" : "bell.slash"
        ) {
            Task { await session.setMuted(!space.isMuted, for: space.name) }
        }

        if space.isPinned {
            let order = pinnedSpaces.map(\.name)
            let index = order.firstIndex(of: space.name)
            Divider()
            Button("Move Up", systemImage: "arrow.up") { movePinned(space, by: -1) }
                .disabled(index == nil || index == 0)
            Button("Move Down", systemImage: "arrow.down") { movePinned(space, by: 1) }
                .disabled(index == nil || index == order.count - 1)
            // Goes through the same offsets-based move as a drag: stepping it up by
            // its own index would swap with the current top rather than move past it,
            // which is a different arrangement entirely.
            Button("Move to Top", systemImage: "arrow.up.to.line") {
                guard let index else { return }
                movePinned(from: IndexSet(integer: index), to: 0)
            }
            .disabled(index == nil || index == 0)
        }
    }

    private struct SpaceGroup {
        let title: String
        let sortOrder: Int
        let spaces: [CachedSpace]
        /// Drives `.onMove`: only this group can be rearranged.
        var isPinned = false
    }

    /// Pinned first, then the sections, then muted — the shape the web client's
    /// sidebar has, built from this app's own pin and mute state.
    ///
    /// Muted conversations are pulled out of their sections rather than shown in
    /// place. Returning them to the sections they came from would scatter the very
    /// rows you asked to keep out of the way through the whole list; a single trailing
    /// group keeps them one glance away instead.
    private var groupedSpaces: [SpaceGroup] {
        let spaces = visibleSpaces
        let pinned = pinnedSpaces
        let muted = spaces.filter { $0.isMuted && !$0.isPinned }
        let rest = spaces.filter { !$0.isPinned && !$0.isMuted }

        // `.min` / `.max` so these two hold their ends of the list even against a
        // custom section the user dragged to the very top or bottom of their sidebar.
        var groups: [SpaceGroup] = []
        if !pinned.isEmpty {
            groups.append(
                SpaceGroup(title: "Pinned", sortOrder: .min, spaces: pinned, isPinned: true)
            )
        }
        if !rest.isEmpty {
            groups.append(contentsOf: sectionGroups(for: rest))
        }
        if !muted.isEmpty {
            groups.append(SpaceGroup(title: "Muted", sortOrder: .max, spaces: muted))
        }
        return groups
    }

    /// Falls back to one flat unlabelled group when sections have not loaded, so the
    /// sidebar never becomes a single header called "Section".
    private func sectionGroups(for spaces: [CachedSpace]) -> [SpaceGroup] {
        let hasSections = spaces.contains { $0.sectionTitle != nil }
        guard hasSections else {
            return [SpaceGroup(title: "Conversations", sortOrder: 0, spaces: spaces)]
        }

        var buckets: [String: [CachedSpace]] = [:]
        var orders: [String: Int] = [:]
        for space in spaces {
            let title = space.sectionTitle ?? "Other"
            buckets[title, default: []].append(space)
            // Ungrouped spaces sort last rather than interleaving with real sections.
            orders[title] = space.sectionTitle == nil ? Int.max : space.sectionSortOrder
        }

        return buckets
            .map { SpaceGroup(title: $0.key, sortOrder: orders[$0.key] ?? 0, spaces: $0.value) }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.title < rhs.title
            }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        switch session.spacesState {
        case .refreshing where allSpaces.isEmpty:
            ProgressView("Loading spaces…")
        case .failed(let message):
            VStack(spacing: 12) {
                Label("Couldn't load spaces", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Retry") { Task { await session.refreshSpaces() } }
            }
            .padding()
        default:
            if visibleSpaces.isEmpty && !allSpaces.isEmpty {
                ContentUnavailableView.search
            }
        }
    }
}

private struct SpaceRow: View {
    let space: CachedSpace
    let peer: CachedUser?

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(space.title)
                    .lineLimit(1)
                    .fontWeight(isUnread ? .semibold : .regular)
                if let active = space.lastActiveTime {
                    Text(active.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            // A pinned space keeps its place at the top whether or not it is muted,
            // so the group header alone cannot say which — this can.
            if space.isMuted && space.isPinned {
                Image(systemName: "bell.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Muted")
            }
            unreadBadge
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind): \(space.title)")
    }

    private var isUnread: Bool { space.unreadCount > 0 || space.hasUnread }

    /// A count when history is cached deeply enough to produce one, otherwise a dot.
    ///
    /// Chat exposes only a read timestamp, never an unread count, so the number is
    /// derived from cached messages. A space whose history has not been backfilled
    /// can be known-unread with a count of zero — showing "0" there would be a lie,
    /// so it gets a dot instead.
    @ViewBuilder
    private var unreadBadge: some View {
        if space.unreadCount > 0 {
            Text("\(space.unreadCount)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor, in: .capsule)
                .accessibilityLabel("\(space.unreadCount) unread")
        } else if space.hasUnread {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Unread")
        }
    }

    /// A person's photo for DMs, a rounded tile for rooms. The shape difference is
    /// what makes the two scannable apart — Chat exposes no space imagery at all.
    @ViewBuilder
    private var icon: some View {
        switch space.spaceType {
        case .directMessage:
            Avatar(name: space.title, photoURL: peer?.photoURL, size: 30)
        case .groupChat:
            SpaceIcon(title: space.title, symbol: "person.2.fill", size: 30)
        default:
            SpaceIcon(title: space.title, symbol: nil, size: 30)
        }
    }

    private var kind: String {
        switch space.spaceType {
        case .directMessage: "Direct message"
        case .groupChat: "Group chat"
        case .space: "Space"
        default: "Conversation"
        }
    }
}
