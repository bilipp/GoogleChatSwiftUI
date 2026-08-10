import SwiftData
import SwiftUI

/// Sidebar + detail. The sidebar is activity-scoped by default because this account
/// has 762 spaces; search reaches all of them regardless of filter.
struct SpacesListView: View {
    @Environment(ChatSessionModel.self) private var session
    @Query(sort: [SortDescriptor(\CachedSpace.lastActiveTime, order: .reverse)])
    private var allSpaces: [CachedSpace]
    /// Directory profiles, for DM avatars. Chat supplies no images of its own.
    @Query private var users: [CachedUser]
    @FocusState private var isSearchFocused: Bool
    /// The row the arrow keys are pointing at while the search field has focus.
    /// Deliberately not the list's selection: moving through results must not open
    /// each conversation it passes over, only the one you press Return on.
    @State private var highlightedSpaceName: String?

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
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { AccountToolbarButton() }
                }
            } else if let selected = selectedSpace {
                MessageListView(
                    spaceName: selected.name,
                    spaceTitle: selected.title,
                    isThreaded: selected.isThreaded,
                    unreadThreadCount: selected.unreadThreadCount,
                    // Read from the space row rather than from the last fetch's answer,
                    // so it stays right across the whole conversation: the backfill
                    // cursor is what knows whether there is anything left to fetch.
                    hasOlderHistory: !selected.backfillComplete
                )
                // Identity tied to the space so switching conversations builds a fresh
                // view. Without it SwiftUI reuses the instance and carries the previous
                // space's scroll offset into the new transcript.
                .id(selected.name)
                .inspector(isPresented: threadBinding) {
                    inspectorContent(for: selected)
                        // The inspector's default width is sized for property
                        // panels, not a conversation — bubbles plus an avatar
                        // need real room or they collapse to a few words a line.
                        .inspectorColumnWidth(min: 380, ideal: 460, max: 760)
                }
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a space or direct message to read it.")
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { AccountToolbarButton() }
                }
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
        // Above every message surface, so a link is caught wherever it was rendered:
        // message text, a smart chip, a card button. `Text`, `Link`, and `CardView` all
        // route through this action rather than reaching AppKit themselves.
        .environment(\.openURL, OpenURLAction(handler: openChatLink))
        // Installed here for the same reason, and at the same level: a person can be
        // clicked in the transcript or in the thread inspector, and both want the one
        // route into a conversation that only this view can open.
        .environment(
            \.openDirectMessage,
            OpenDirectMessageAction { userID in
                Task { await openDirectMessage(with: userID) }
            }
        )
        .task {
            // First, because this is a click that landed before the view existed —
            // the one that launched the app — and the loaders below run in bounded
            // passes that take seconds. The cache is already on disk, so the
            // conversation opens without waiting for any of them.
            await openFromNotification()
            if case .idle = session.spacesState { await session.refreshSpaces() }
            await session.startRealtime()
            await session.prepareSearchIndex()
            // Before read states, so the marks those bring back land on threads that
            // already exist rather than leaving the cache's threads unseeded.
            await session.prepareThreadIndex()
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
        .onReceive(NotificationCenter.default.publisher(for: .chatMarkUnread)) { _ in
            guard let name = session.selectedSpaceName else { return }
            Task { await session.markUnread(name) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatFocusSearch)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatToggleThreads)) { _ in
            // Ignored where threads are not a place of their own, matching the
            // toolbar button rather than opening an index that would list nothing.
            guard let space = selectedSpace, space.isThreaded else { return }
            if session.isThreadListOpen {
                session.closeThreadInspector()
            } else {
                session.openThreadList()
            }
        }
    }

    /// Opens the conversation a clicked notification named.
    private func openFromNotification() async {
        guard let name = NotificationRouter.shared.claimPendingSpace() else { return }
        unhide(name)
        await session.revealSpace(name)
    }

    /// Follows a `chat.google.com` link inside the app instead of in a browser.
    ///
    /// A message link pasted into a conversation points at another conversation this app
    /// already has open behind it, so handing it to a browser tab — where the reader has
    /// to sign in, wait for the web client to load, and then read it somewhere else — is
    /// the one thing a native client should not do with it.
    ///
    /// Only links this account can actually follow are claimed. A space nobody here is a
    /// member of, and every other URL on the web, gets the system action it would have
    /// had anyway. The check is against the cached space list because the decision has to
    /// be made now, synchronously, before the click is either handled or passed on.
    private func openChatLink(_ url: URL) -> OpenURLAction.Result {
        guard let link = ChatDeepLink(url: url),
              allSpaces.contains(where: { $0.name == link.spaceName })
        else { return .systemAction }

        unhide(link.spaceName)
        Task { await session.reveal(link) }
        return .handled
    }

    /// Opens the chat with a person, from wherever they were clicked.
    ///
    /// The conversation may be one this account has never had, in which case it is
    /// created — see `SyncEngine.directMessage(with:)` — and a brand-new row can be a
    /// runloop behind the sidebar's own query. `unhide` can only relax filters for a row
    /// it can already see, so the one filter that would certainly hide a direct message
    /// is cleared first, whether or not the row has arrived.
    private func openDirectMessage(with userID: String) async {
        guard let spaceName = await session.directMessageSpace(with: userID) else { return }
        if session.kind == .spaces { session.kind = .all }
        unhide(spaceName)
        await session.revealSpace(spaceName)
    }

    /// Relaxes any filter that would hide a conversation being opened from outside the
    /// sidebar.
    ///
    /// The filters are a browsing preference, not a reason to refuse an explicit
    /// request — and without this the transcript opens with no matching sidebar row,
    /// leaving no sense of where you are. The search field needs no handling: opening a
    /// conversation clears it.
    private func unhide(_ spaceName: String) {
        guard let space = allSpaces.first(where: { $0.name == spaceName }) else { return }
        if !session.kind.matches(space) { session.kind = .all }
        if !session.scope.matches(space, now: Date()) { session.scope = .all }
        if space.isMuted { session.showsMuted = true }
    }

    /// The thread index and a single thread are two views of the same panel, so they
    /// share the inspector rather than competing for the same edge of the window.
    @ViewBuilder
    private func inspectorContent(for space: CachedSpace) -> some View {
        switch session.threadInspector {
        case .closed:
            EmptyView()
        case .list:
            ThreadListPane(spaceName: space.name)
                // Per space, so the unread filter and scroll position do not carry
                // across to a different conversation's threads.
                .id(space.name)
        case .thread(let thread, _):
            ThreadPane(spaceName: space.name, threadName: thread)
                // Likewise per thread, so reopening a different thread does not
                // inherit the last one's position.
                .id(thread)
        }
    }

    /// The inspector's own dismiss control closes the panel outright, keeping the
    /// model in step with a close the user performed via the window chrome.
    private var threadBinding: Binding<Bool> {
        Binding(
            get: { session.threadInspector != .closed },
            set: { shown in if !shown { session.closeThreadInspector() } }
        )
    }

    private var selectedSpace: CachedSpace? {
        guard let name = session.selectedSpaceName else { return nil }
        return allSpaces.first { $0.name == name }
    }

    private var sidebar: some View {
        @Bindable var session = session
        // One pass over the space list for the whole sidebar — see ``SidebarIndex``.
        let index = SidebarIndex(
            spaces: allSpaces,
            users: users,
            scope: session.scope,
            kind: session.kind,
            showsMuted: session.showsMuted,
            searchText: session.searchText
        )

        return ScrollViewReader { proxy in
            List(selection: Binding(
                get: { session.selectedSpaceName },
                set: { name in
                    guard let name else { return }
                    Task { await session.openSpace(name) }
                }
            )) {
                ForEach(index.groups, id: \.title) { group in
                    Section(group.title) {
                        // Identified by name so `scrollTo` below can name a row. The
                        // model's own identifier would work for the list but is not
                        // something the highlight has in hand.
                        ForEach(group.spaces, id: \.name) { space in
                            SpaceRow(
                                space: space,
                                peer: index.peer(for: space),
                                isHighlighted: space.name == highlightedSpaceName
                            )
                            .tag(space.name)
                            .contextMenu { rowMenu(for: space, index: index) }
                        }
                        .onMove(perform: moveHandler(for: group, index: index))
                    }
                }
            }
            // Dissolves rows into the header instead of letting them slide under it.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .overlay { emptyOverlay(index) }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    SidebarSearchField(
                        text: $session.searchText,
                        placeholder: "Search conversations",
                        isFocused: $isSearchFocused,
                        onMoveHighlight: { delta in moveHighlight(by: delta, in: index) },
                        onOpenHighlighted: openHighlighted,
                        onCancel: cancelSearch
                    )
                    SidebarFilterBar(
                        scope: $session.scope,
                        kind: $session.kind,
                        showsMuted: $session.showsMuted,
                        scopeCounts: index.scopeCounts,
                        kindCounts: index.kindCounts,
                        mutedCount: index.mutedCount,
                        visibleCount: index.visibleSpaces.count
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
            // The highlight is useless off screen, and with hundreds of rows behind
            // the filter it leaves the viewport within a few presses.
            .onChange(of: highlightedSpaceName) { _, name in
                guard let name else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(name, anchor: .center)
                }
            }
            // A new query means new results: point at the top hit so Return has a
            // visible target without an arrow press first.
            .onChange(of: session.searchText) { _, _ in
                highlightedSpaceName = defaultHighlight(index)
            }
            // Once focus leaves the field the arrows belong to the list itself, and
            // a highlight left behind would claim a target they no longer move.
            .onChange(of: isSearchFocused) { _, focused in
                highlightedSpaceName = focused ? defaultHighlight(index) : nil
            }
        }
    }

    /// Where the highlight sits before any arrow press: on the top hit once there is
    /// a query, and nowhere at all while the field is empty — a highlight on row one
    /// of an unfiltered list of 762 would be pointing at nothing in particular.
    private func defaultHighlight(_ index: SidebarIndex) -> String? {
        session.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : index.orderedSpaceNames.first
    }

    private func moveHighlight(by delta: Int, in index: SidebarIndex) {
        highlightedSpaceName = SidebarHighlight.moved(
            from: highlightedSpaceName,
            by: delta,
            in: index.orderedSpaceNames
        )
    }

    /// Return opens the highlighted conversation and hands focus back to the
    /// transcript. Emptying the field is `openSpace`'s job, so that a row reached by
    /// Return and one reached by a click leave the sidebar in the same state.
    private func openHighlighted() {
        guard let name = highlightedSpaceName else {
            isSearchFocused = false
            return
        }
        isSearchFocused = false
        Task { await session.openSpace(name) }
    }

    /// Escape clears the query first and only gives up focus on a second press, so
    /// it never dismisses the field while there is still a filter left applied.
    private func cancelSearch() {
        if session.searchText.isEmpty {
            isSearchFocused = false
        } else {
            session.searchText = ""
        }
    }

    /// Only the pinned group is arrangeable: the others are ordered by the server's
    /// section order and by recency, neither of which is this app's to overrule.
    /// `nil` leaves those rows undraggable.
    ///
    /// Spelled out as a typed closure rather than a ternary inside the list body,
    /// which pushed that expression past what the type checker would solve.
    private func moveHandler(
        for group: SpaceGroup,
        index: SidebarIndex
    ) -> ((IndexSet, Int) -> Void)? {
        guard group.isPinned else { return nil }
        return { offsets, destination in
            movePinned(from: offsets, to: destination, in: index)
        }
    }

    /// Drag-to-reorder within the pinned section.
    private func movePinned(from offsets: IndexSet, to destination: Int, in index: SidebarIndex) {
        var names = index.pinnedSpaces.map(\.name)
        names.move(fromOffsets: offsets, toOffset: destination)
        Task { await session.reorderPinned(names) }
    }

    /// The same reorder by one step, for the context menu.
    ///
    /// Dragging is the obvious gesture but the worst one to rely on alone here: the
    /// rows are also a selection list, the group can be taller than the sidebar, and
    /// a drag is unreachable by keyboard or VoiceOver.
    private func movePinned(_ space: CachedSpace, by delta: Int, in index: SidebarIndex) {
        var names = index.pinnedSpaces.map(\.name)
        guard let position = names.firstIndex(of: space.name),
              names.indices.contains(position + delta)
        else { return }
        names.swapAt(position, position + delta)
        Task { await session.reorderPinned(names) }
    }

    @ViewBuilder
    private func rowMenu(for space: CachedSpace, index: SidebarIndex) -> some View {
        // Unlike pin and mute, this one is Chat's own read state rather than local
        // decoration, so it shows up on chat.google.com too.
        if space.isUnread {
            Button("Mark as Read", systemImage: "envelope.open") {
                Task { await session.markRead(space.name) }
            }
        } else {
            Button("Mark as Unread", systemImage: "envelope.badge") {
                Task { await session.markUnread(space.name) }
            }
        }
        Divider()

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
            let order = index.pinnedSpaces.map(\.name)
            let position = order.firstIndex(of: space.name)
            Divider()
            Button("Move Up", systemImage: "arrow.up") { movePinned(space, by: -1, in: index) }
                .disabled(position == nil || position == 0)
            Button("Move Down", systemImage: "arrow.down") { movePinned(space, by: 1, in: index) }
                .disabled(position == nil || position == order.count - 1)
            // Goes through the same offsets-based move as a drag: stepping it up by
            // its own index would swap with the current top rather than move past it,
            // which is a different arrangement entirely.
            Button("Move to Top", systemImage: "arrow.up.to.line") {
                guard let position else { return }
                movePinned(from: IndexSet(integer: position), to: 0, in: index)
            }
            .disabled(position == nil || position == 0)
        }
    }

    @ViewBuilder
    private func emptyOverlay(_ index: SidebarIndex) -> some View {
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
            if index.visibleSpaces.isEmpty && !allSpaces.isEmpty {
                ContentUnavailableView.search
            }
        }
    }
}

private struct SpaceGroup {
    let title: String
    let sortOrder: Int
    let spaces: [CachedSpace]
    /// Drives `.onMove`: only this group can be rearranged.
    var isPinned = false
}

/// Everything the sidebar derives from the space list, worked out once per body
/// evaluation.
///
/// These were computed properties, and the filtered list underneath them was being
/// rebuilt five times a pass over 762 rows — by the grouping, by the pinned group, by
/// the filter bar's count, by the empty overlay, and again by the order the arrow keys
/// walk. Worse, `peer(for:)` reached for a dictionary of every directory row and was
/// called *per row drawn*, which is the same O(rows × cache) trap the transcript had.
///
/// The counts are the reason this takes the filter state as parameters rather than
/// reading the session: they describe what each option *would* show, so each is
/// measured against the other axis's current setting rather than its own.
private struct SidebarIndex {
    /// The rows the sidebar shows, before grouping.
    let visibleSpaces: [CachedSpace]
    /// Pinned first, then the sections, then muted — the shape the web client's
    /// sidebar has, built from this app's own pin and mute state.
    let groups: [SpaceGroup]
    /// The pinned group in the arrangement the user chose.
    let pinnedSpaces: [CachedSpace]
    /// Every visible row in the order the sidebar draws it, groups included — so the
    /// arrows walk the list as it looks rather than as it was assembled.
    let orderedSpaceNames: [String]
    /// How many rows each scope would show, honouring the current kind — so the
    /// numbers in the menu match what picking that option actually produces.
    let scopeCounts: [SpaceScope: Int]
    let kindCounts: [SpaceKind: Int]
    /// Pinned rows are counted out: they are listed regardless of the muted toggle, so
    /// including them would promise rows the toggle cannot actually reveal.
    let mutedCount: Int
    private let usersByID: [String: CachedUser]

    init(
        spaces: [CachedSpace],
        users: [CachedUser],
        scope: SpaceScope,
        kind: SpaceKind,
        showsMuted: Bool,
        searchText: String
    ) {
        usersByID = Dictionary(
            users.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let now = Date()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Search overrides the scope — if you're looking for a dormant DM by name,
        // having "Recent" silently hide it would be actively unhelpful. The kind filter
        // still applies, since that is a deliberate narrowing rather than a time limit.
        var visible: [CachedSpace] = []
        var scopeTally: [SpaceScope: Int] = [:]
        var kindTally: [SpaceKind: Int] = [:]
        var muted = 0

        // One walk of the list for all four answers. Each was its own pass before, and
        // the two tallies were a pass per option on top of that.
        for space in spaces {
            let matchesKind = kind.matches(space)
            let matchesScope = scope.matches(space, now: now)

            if !query.isEmpty {
                if matchesKind, space.title.localizedCaseInsensitiveContains(query) {
                    visible.append(space)
                }
            } else if matchesKind {
                // Pinning outranks both the scope and the muted toggle: it is an
                // explicit "keep this in front of me", and a pin that vanished because
                // the conversation went quiet for a month would be worse than no pin.
                if space.isPinned {
                    visible.append(space)
                } else if showsMuted || !space.isMuted, matchesScope {
                    visible.append(space)
                }
            }

            for option in SpaceScope.allCases where matchesKind && option.matches(space, now: now) {
                scopeTally[option, default: 0] += 1
            }
            for option in SpaceKind.allCases where matchesScope && option.matches(space) {
                kindTally[option, default: 0] += 1
            }
            if space.isMuted, !space.isPinned, matchesScope, matchesKind { muted += 1 }
        }

        // Absent keys would read as "no count at all" rather than "none": the filter bar
        // shows the number next to every option, including the ones that match nothing.
        for option in SpaceScope.allCases where scopeTally[option] == nil { scopeTally[option] = 0 }
        for option in SpaceKind.allCases where kindTally[option] == nil { kindTally[option] = 0 }

        visibleSpaces = visible
        scopeCounts = scopeTally
        kindCounts = kindTally
        mutedCount = muted

        // Pinned wins over muted for a space that is both: you can pin something you
        // have silenced, and the pin is the more deliberate of the two instructions.
        // Ties fall back to the query's recency order, so a group pinned before ordering
        // existed still lists in a stable, sensible sequence.
        pinnedSpaces = visible.filter(\.isPinned).sorted { $0.pinnedOrder < $1.pinnedOrder }

        // Muted conversations are pulled out of their sections rather than shown in
        // place. Returning them to the sections they came from would scatter the very
        // rows you asked to keep out of the way through the whole list; a single
        // trailing group keeps them one glance away instead.
        let mutedGroup = visible.filter { $0.isMuted && !$0.isPinned }
        let rest = visible.filter { !$0.isPinned && !$0.isMuted }

        // `.min` / `.max` so these two hold their ends of the list even against a
        // custom section the user dragged to the very top or bottom of their sidebar.
        var assembled: [SpaceGroup] = []
        if !pinnedSpaces.isEmpty {
            assembled.append(
                SpaceGroup(
                    title: "Pinned",
                    sortOrder: .min,
                    spaces: pinnedSpaces,
                    isPinned: true
                )
            )
        }
        if !rest.isEmpty {
            assembled.append(contentsOf: Self.sectionGroups(for: rest))
        }
        if !mutedGroup.isEmpty {
            assembled.append(SpaceGroup(title: "Muted", sortOrder: .max, spaces: mutedGroup))
        }
        groups = assembled
        orderedSpaceNames = assembled.flatMap { $0.spaces.map(\.name) }
    }

    /// The single other person in a DM. Group chats intentionally get a tile instead
    /// of one arbitrary member's face.
    func peer(for space: CachedSpace) -> CachedUser? {
        guard space.spaceType == .directMessage,
              let id = space.peerUserIDs.first
        else { return nil }
        return usersByID[id]
    }

    /// Falls back to one flat unlabelled group when sections have not loaded, so the
    /// sidebar never becomes a single header called "Section".
    private static func sectionGroups(for spaces: [CachedSpace]) -> [SpaceGroup] {
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
}

private struct SpaceRow: View {
    let space: CachedSpace
    let peer: CachedUser?
    /// Where the search field's arrow keys are pointing. Drawn as a ring rather than
    /// a fill so it cannot be mistaken for the selected row — the two are frequently
    /// different rows, and the whole point is that this one is not open yet.
    var isHighlighted = false

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(space.title)
                    .lineLimit(1)
                    .fontWeight(space.isUnread ? .semibold : .regular)
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
            threadBadge
            unreadBadge
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind): \(space.title)")
        // Not `.isSelected`: that trait belongs to the open conversation, and this
        // row is only the one Return would open.
        .accessibilityValue(isHighlighted ? "Highlighted" : "")
    }

    /// Unread replies waiting inside threads, which the message badge cannot speak
    /// for: the space's read mark clears the moment it is opened, while the replies
    /// behind it stay unread and stay off the transcript. Without this the sidebar
    /// would show a fully-read conversation that still has something to read in it.
    @ViewBuilder
    private var threadBadge: some View {
        if space.unreadThreadCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption2)
                Text("\(space.unreadThreadCount)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("\(space.unreadThreadCount) unread threads")
        }
    }

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
