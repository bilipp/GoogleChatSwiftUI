import SwiftData
import SwiftUI

/// Sidebar + detail. The sidebar is activity-scoped by default because this account
/// has 762 spaces; search reaches all of them regardless of filter.
///
/// Neither half reads the whole space list any more. Both own a `@Query` narrowed to what
/// they actually draw — the sidebar to the current filter, the detail to the one open
/// conversation — because `@Query` refetches on every write to the store and materializing
/// 769 `CachedSpace` rows costs ~52ms of main-thread work each time. See ``SpaceQueries``.
/// The queries live in child views for a mechanical reason: a `@Query` predicate can only
/// be built in `init`, and the filter state lives in `session`, which an initializer
/// cannot reach.
struct SpacesListView: View {
    @Environment(ChatSessionModel.self) private var session
    /// For the by-name lookups that used to read the full list: following a link,
    /// relaxing the filters around a conversation being opened from elsewhere.
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isSearchFocused: Bool
    /// Focus of the toolbar's message-search field, so ⌘⇧F can put the caret there.
    /// Separate from the sidebar's: the two fields search different things and are
    /// both on screen at once.
    @FocusState private var isMessageSearchFocused: Bool

    var body: some View {
        @Bindable var session = session

        NavigationSplitView {
            SidebarSpaceList(
                scope: session.scope,
                kind: session.kind,
                showsMuted: session.showsMuted,
                searchText: session.searchText,
                isSearchFocused: $isSearchFocused
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            detail
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
        // The one handle SwiftUI offers on a search field it owns. A `@FocusState`
        // attached to some view of ours could not reach it: the field is built by
        // `.searchable` and hosted in the toolbar, outside this hierarchy entirely.
        .searchFocused($isMessageSearchFocused)
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
        .onReceive(NotificationCenter.default.publisher(for: .chatFocusMessageSearch)) { _ in
            // Only takes focus; a query already typed is left standing so the shortcut
            // can also be used to get back to a result list you clicked away from.
            isMessageSearchFocused = true
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

    @ViewBuilder
    private var detail: some View {
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
        } else if let name = session.selectedSpaceName {
            // Identity tied to the space so switching conversations builds a fresh view.
            // Without it SwiftUI reuses the instance and carries the previous space's
            // scroll offset into the new transcript.
            ConversationDetail(spaceName: name)
                .id(name)
        } else {
            noConversation
        }
    }

    private var noConversation: some View {
        ContentUnavailableView(
            "No Conversation Selected",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Pick a space or direct message to read it.")
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) { AccountToolbarButton() }
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
        guard let link = ChatDeepLink(url: url), isCached(link.spaceName) else {
            return .systemAction
        }

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
        guard let space = space(named: spaceName) else { return }
        if !session.kind.matches(space) { session.kind = .all }
        if !session.scope.matches(space, now: Date()) { session.scope = .all }
        if space.isMuted { session.showsMuted = true }
    }

    /// The open conversation's row, for the few places outside the detail pane that need
    /// it. Fetched by name rather than found in a list, since no view here holds one.
    private var selectedSpace: CachedSpace? {
        session.selectedSpaceName.flatMap(space(named:))
    }

    private func space(named spaceName: String) -> CachedSpace? {
        var descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate { $0.name == spaceName }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Whether this account knows the space at all — a count rather than a fetch, since
    /// the answer is a yes or no and a row would be thrown away.
    private func isCached(_ spaceName: String) -> Bool {
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { $0.name == spaceName }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0 > 0
    }
}

/// The open conversation, with the thread inspector beside it.
///
/// Owns a `@Query` for its one space rather than being handed a row found in the sidebar's
/// list: the sidebar's query is narrowed to the current filter now, and a conversation can
/// outlive its place in it — one left open long enough to age out of "Recent" would
/// otherwise vanish from the pane it is being read in.
private struct ConversationDetail: View {
    @Environment(ChatSessionModel.self) private var session
    @Query private var spaces: [CachedSpace]

    private let spaceName: String

    init(spaceName: String) {
        self.spaceName = spaceName
        var descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate { $0.name == spaceName }
        )
        descriptor.fetchLimit = 1
        _spaces = Query(descriptor)
    }

    var body: some View {
        if let space = spaces.first {
            MessageListView(
                spaceName: space.name,
                spaceTitle: space.title,
                isThreaded: space.isThreaded,
                unreadThreadCount: space.unreadThreadCount,
                // Read from the space row rather than from the last fetch's answer,
                // so it stays right across the whole conversation: the backfill
                // cursor is what knows whether there is anything left to fetch.
                hasOlderHistory: !space.backfillComplete
            )
            .inspector(isPresented: threadBinding) {
                inspectorContent(for: space)
                    // The inspector's default width is sized for property
                    // panels, not a conversation — bubbles plus an avatar
                    // need real room or they collapse to a few words a line.
                    .inspectorColumnWidth(min: 380, ideal: 460, max: 760)
            }
        } else {
            // The row has not arrived yet — a direct message created moments ago can be
            // a runloop behind its own query.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { AccountToolbarButton() }
                }
        }
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
}

/// The conversation list.
///
/// Owns the narrowed `@Query`, which is why it is a view of its own: a predicate can only
/// be built in `init`, so the filter state has to arrive as parameters rather than be read
/// from `session`. See ``SpaceQueries`` for what the narrowing is worth.
private struct SidebarSpaceList: View {
    @Environment(ChatSessionModel.self) private var session
    @Environment(\.modelContext) private var modelContext
    /// Rows the current filter could show — a superset of what is drawn, which
    /// ``SidebarIndex`` then narrows exactly.
    @Query private var spaces: [CachedSpace]
    /// Directory profiles, for DM avatars. Chat supplies no images of its own.
    @Query private var users: [CachedUser]
    @FocusState.Binding private var isSearchFocused: Bool
    /// The row the arrow keys are pointing at while the search field has focus.
    /// Deliberately not the list's selection: moving through results must not open
    /// each conversation it passes over, only the one you press Return on.
    @State private var highlightedSpaceName: String?

    private let scope: SpaceScope
    private let kind: SpaceKind
    private let showsMuted: Bool
    private let searchText: String

    init(
        scope: SpaceScope,
        kind: SpaceKind,
        showsMuted: Bool,
        searchText: String,
        isSearchFocused: FocusState<Bool>.Binding
    ) {
        self.scope = scope
        self.kind = kind
        self.showsMuted = showsMuted
        self.searchText = searchText
        _isSearchFocused = isSearchFocused

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        _spaces = Query(
            // Only whether there *is* a query, not what it says: the text is matched in
            // memory, so typing narrows the same fetched set instead of asking SQLite
            // again on every keystroke.
            filter: SpaceQueries.sidebarRows(
                scope: scope,
                kind: kind,
                hasSearchQuery: !query.isEmpty,
                now: Date()
            ),
            sort: [SortDescriptor(\CachedSpace.lastActiveTime, order: .reverse)]
        )
    }

    var body: some View {
        @Bindable var session = session
        // One pass over the fetched rows for the whole sidebar — see ``SidebarIndex``.
        let index = SidebarIndex(
            spaces: spaces,
            users: users,
            scope: scope,
            kind: kind,
            showsMuted: showsMuted,
            searchText: searchText
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
                        // Eager, unlike the rest: the button's own title and the Muted
                        // item's enabled state both depend on it, so it is read whether
                        // or not the menu is ever opened. One count, a quarter of a
                        // millisecond.
                        mutedCount: mutedCount,
                        visibleCount: index.visibleSpaces.count,
                        // Deferred, because these are only ever read inside the menu's
                        // content. Seven counts is about 7ms — worth not paying on every
                        // pass of a list that redraws whenever the store is written to.
                        counts: menuCounts
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
            .onChange(of: searchText) { _, _ in
                highlightedSpaceName = defaultHighlight(index)
            }
            // Once focus leaves the field the arrows belong to the list itself, and
            // a highlight left behind would claim a target they no longer move.
            .onChange(of: isSearchFocused) { _, focused in
                highlightedSpaceName = focused ? defaultHighlight(index) : nil
            }
        }
    }

    // MARK: - Counts

    private var mutedCount: Int {
        (try? SidebarCounts.count(
            scope: scope,
            kind: kind,
            mutedOnly: true,
            now: Date(),
            in: modelContext
        )) ?? 0
    }

    /// What each option in the filter menu would list. Measured against the *other*
    /// axis's current setting, so each number is what picking that one option produces.
    private func menuCounts() -> SidebarOptionCounts {
        let now = Date()
        var byScope: [SpaceScope: Int] = [:]
        for option in SpaceScope.allCases {
            byScope[option] = (try? SidebarCounts.count(
                scope: option, kind: kind, now: now, in: modelContext
            )) ?? 0
        }
        var byKind: [SpaceKind: Int] = [:]
        for option in SpaceKind.allCases {
            byKind[option] = (try? SidebarCounts.count(
                scope: scope, kind: option, now: now, in: modelContext
            )) ?? 0
        }
        return SidebarOptionCounts(scope: byScope, kind: byKind)
    }

    /// Whether anything is cached at all, which is what separates "still loading" from
    /// "your filter matches nothing". A count, since the rows would be discarded.
    private var hasAnySpaces: Bool {
        ((try? modelContext.fetchCount(FetchDescriptor<CachedSpace>())) ?? 0) > 0
    }

    // MARK: - Highlight

    /// Where the highlight sits before any arrow press: on the top hit once there is
    /// a query, and nowhere at all while the field is empty — a highlight on row one
    /// of an unfiltered list of 762 would be pointing at nothing in particular.
    private func defaultHighlight(_ index: SidebarIndex) -> String? {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    // MARK: - Reordering

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
        case .refreshing where !hasAnySpaces:
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
            if index.visibleSpaces.isEmpty && hasAnySpaces {
                ContentUnavailableView.search
            }
        }
    }
}

struct SpaceGroup {
    let title: String
    let sortOrder: Int
    let spaces: [CachedSpace]
    /// Drives `.onMove`: only this group can be rearranged.
    var isPinned = false
}

/// Everything the sidebar derives from the rows it fetched, worked out once per body
/// evaluation.
///
/// These were computed properties, and the filtered list underneath them was being
/// rebuilt five times a pass — by the grouping, by the pinned group, by the filter bar's
/// count, by the empty overlay, and again by the order the arrow keys walk. Worse,
/// `peer(for:)` reached for a dictionary of every directory row and was called *per row
/// drawn*, which is the same O(rows × cache) trap the transcript had.
///
/// The counts used to be tallied here too, in the same pass. They moved to
/// ``SidebarCounts`` when the fetch stopped returning every space: a number describing
/// rows outside the current filter cannot be derived from rows inside it.
struct SidebarIndex {
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
        //
        // Still applied here rather than left to the fetch: `spaces` is only a superset,
        // deliberately, so this pass remains the authority on what is drawn.
        var visible: [CachedSpace] = []
        for space in spaces {
            guard kind.matches(space) else { continue }

            if !query.isEmpty {
                if space.title.localizedCaseInsensitiveContains(query) {
                    visible.append(space)
                }
            } else if space.isPinned {
                // Pinning outranks both the scope and the muted toggle: it is an
                // explicit "keep this in front of me", and a pin that vanished because
                // the conversation went quiet for a month would be worse than no pin.
                visible.append(space)
            } else if showsMuted || !space.isMuted, scope.matches(space, now: now) {
                visible.append(space)
            }
        }

        visibleSpaces = visible

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
