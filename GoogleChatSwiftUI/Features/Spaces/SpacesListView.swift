import SwiftData
import SwiftUI

/// Sidebar + detail. The sidebar is activity-scoped by default because this account
/// has 762 spaces; search reaches all of them regardless of filter.
struct SpacesListView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(ChatSessionModel.self) private var session
    @Query(sort: [SortDescriptor(\CachedSpace.lastActiveTime, order: .reverse)])
    private var allSpaces: [CachedSpace]

    var body: some View {
        @Bindable var session = session

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let selected = selectedSpace {
                MessageListView(spaceName: selected.name, spaceTitle: selected.title)
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a space or direct message to read it.")
                )
            }
        }
        .task {
            if case .idle = session.spacesState { await session.refreshSpaces() }
        }
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
            ForEach(visibleSpaces) { space in
                SpaceRow(space: space).tag(space.name)
            }
        }
        .searchable(text: $session.searchText, prompt: "Search all \(allSpaces.count) spaces")
        .overlay { emptyOverlay }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Filter", selection: $session.filter) {
                ForEach(SpaceFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.systemImage).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .padding(8)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.refreshSpaces() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(session.isRefreshingSpaces)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Sign Out") { Task { await auth.signOut() } }
            }
        }
    }

    /// Search overrides the filter — if you're looking for a dormant DM by name,
    /// having "Recent" silently hide it would be actively unhelpful.
    private var visibleSpaces: [CachedSpace] {
        let query = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return allSpaces.filter {
                $0.title.localizedCaseInsensitiveContains(query)
            }
        }
        let now = Date()
        return allSpaces.filter { session.filter.matches($0, now: now) }
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

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(space.title).lineLimit(1)
                if let active = space.lastActiveTime {
                    Text(active.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
        .accessibilityLabel("\(kind): \(space.title)")
    }

    private var icon: String {
        switch space.spaceType {
        case .directMessage: "person.fill"
        case .groupChat: "person.2.fill"
        case .space: "number"
        default: "bubble.left"
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
