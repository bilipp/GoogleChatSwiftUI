import SwiftData
import SwiftUI

nonisolated enum MessageSearchScope: String, CaseIterable, Identifiable, Sendable {
    case allConversations
    case currentConversation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allConversations: "All conversations"
        case .currentConversation: "This conversation"
        }
    }
}

/// Results for a message search: the cache first, then Chat's own search.
///
/// The cache answers instantly but only knows history that has been downloaded, which
/// happens lazily per conversation. Chat's `messages.search` covers everything, but
/// leaves out muted spaces and app messages and costs a round trip. Both run: cached
/// matches show at once, server hits the cache doesn't already have follow below.
///
/// Server hits stay in memory. See ``SyncEngine/searchMessages(query:inSpace:)`` for
/// why they are not written to the cache.
struct MessageSearchResults: View {
    @Environment(ChatSessionModel.self) private var session
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openChatMessage) private var openChatMessage
    @Query private var matches: [CachedMessage]

    @State private var serverHits: [ChatMessage] = []
    @State private var serverState: ServerState = .loading
    @State private var spaceTitles: [String: String] = [:]

    private let query: String
    private let spaceName: String?

    private enum ServerState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    init(query: String, scopedTo spaceName: String?) {
        self.query = query
        self.spaceName = spaceName
        let needle = query.lowercased()

        // Two whole descriptors rather than one with a conditional predicate.
        // `#Predicate` expands into a value pack and cannot be produced by an
        // `if`-expression — the macro has to sit directly in an argument list.
        var descriptor: FetchDescriptor<CachedMessage>
        if let spaceName {
            descriptor = FetchDescriptor<CachedMessage>(
                predicate: #Predicate<CachedMessage> { message in
                    message.searchableText.contains(needle) && message.space?.name == spaceName
                },
                sortBy: [SortDescriptor(\CachedMessage.createTime, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<CachedMessage>(
                predicate: #Predicate<CachedMessage> { message in
                    message.searchableText.contains(needle)
                },
                sortBy: [SortDescriptor(\CachedMessage.createTime, order: .reverse)]
            )
        }
        // Capped: an unqualified query like "the" would otherwise pull thousands of
        // rows into a list nobody scrolls.
        descriptor.fetchLimit = 200
        _matches = Query(descriptor)
    }

    var body: some View {
        Group {
            if matches.isEmpty && newServerHits.isEmpty && serverState != .loading {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text(emptyDescription)
                }
            } else {
                list
            }
        }
        .navigationTitle("Search")
        .task { await searchServer() }
    }

    private var emptyDescription: String {
        if case .failed(let reason) = serverState {
            return "Nothing found for “\(query)” in downloaded history, and Google Chat search failed: \(reason)"
        }
        return "Nothing found for “\(query)”. Google Chat search leaves out muted conversations and messages from apps."
    }

    /// Server hits the cache did not already match, so nothing is listed twice.
    private var newServerHits: [ChatMessage] {
        let local = Set(matches.map(\.name))
        return serverHits.filter { !local.contains($0.name) }
    }

    private var list: some View {
        // The window's one directory snapshot, already keyed. This was a `@Query` of
        // every `CachedUser` and a dictionary built over it here — a full main-thread
        // fetch on every write to the store. See ``DirectoryCache``.
        let usersByID = session.directory.profiles
        let fromServer = newServerHits

        return List {
            if !matches.isEmpty {
                Section {
                    ForEach(matches) { message in
                        Button {
                            open(message)
                        } label: {
                            MessageSearchRow(
                                identity: SenderIdentity(
                                    message: message,
                                    sender: message.senderName.flatMap { usersByID[$0] }
                                ),
                                spaceTitle: message.space?.title ?? "",
                                createTime: message.createTime,
                                text: message.summaryText,
                                query: query
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(countLabel)
                }
            }

            Section {
                ForEach(fromServer, id: \.name) { message in
                    Button {
                        open(message)
                    } label: {
                        MessageSearchRow(
                            identity: identity(of: message, usersByID: usersByID),
                            spaceTitle: ChatEvent.space(fromMessageName: message.name)
                                .flatMap { spaceTitles[$0] } ?? "",
                            createTime: message.createTime,
                            text: message.displayText,
                            query: query
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("From Google Chat")
                    if serverState == .loading {
                        ProgressView().controlSize(.mini)
                    }
                }
            } footer: {
                Text(serverFooter(hasHits: !fromServer.isEmpty))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func serverFooter(hasHits: Bool) -> String {
        switch serverState {
        case .loading:
            "Searching all of your history…"
        case .failed(let reason):
            "Google Chat search failed: \(reason)"
        case .loaded:
            hasHits
                ? "Muted conversations and messages from apps aren't included."
                : "Nothing further beyond downloaded history. Muted conversations and messages from apps aren't included."
        }
    }

    private var countLabel: String {
        matches.count >= 200
            ? "First 200 downloaded matches"
            : "\(matches.count) downloaded match\(matches.count == 1 ? "" : "es")"
    }

    private func identity(of message: ChatMessage, usersByID: [String: UserProfile]) -> SenderIdentity {
        let profile = message.sender?.name.flatMap { usersByID[$0] }
        return SenderIdentity(
            resolvedName: profile?.displayName ?? message.sender?.displayName,
            photoURL: profile?.photoURL,
            isApp: profile?.isApp == true || message.sender?.type == .bot
        )
    }

    private func searchServer() async {
        // Debounced by the view's identity: each keystroke builds a new view and
        // cancels this task, so only a pause in typing reaches the network.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        do {
            let hits = try await session.searchServerMessages(query, inSpace: spaceName)
            guard !Task.isCancelled else { return }
            spaceTitles = titles(for: hits)
            serverHits = hits
            serverState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            serverState = .failed(error.localizedDescription)
        }
    }

    /// Conversation names for the hits, read from the cache in one fetch.
    private func titles(for hits: [ChatMessage]) -> [String: String] {
        let names = Set(hits.compactMap { ChatEvent.space(fromMessageName: $0.name) })
        guard !names.isEmpty else { return [:] }
        let wanted = Array(names)
        let descriptor = FetchDescriptor<CachedSpace>(
            predicate: #Predicate<CachedSpace> { wanted.contains($0.name) }
        )
        let spaces = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(spaces.map { ($0.name, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// Opens the containing conversation and asks the transcript to jump to the hit.
    private func open(_ message: CachedMessage) {
        guard let space = message.space?.name else { return }
        Task {
            await session.openSpace(space)
            session.jump(to: message.name)
            session.messageQuery = ""
        }
    }

    /// A server hit is, by being listed here, not cached — usually because it is older
    /// than the history downloaded so far. It goes the way a forwarded message does, so
    /// the sidebar makes room for the conversation, and with its send time, so the
    /// transcript fetches back as far as it needs to rather than the few pages a pasted
    /// link gets.
    private func open(_ message: ChatMessage) {
        guard let space = ChatEvent.space(fromMessageName: message.name) else { return }
        openChatMessage(message.name, in: space, sentAt: message.createTime ?? .distantPast)
    }
}

private struct MessageSearchRow: View {
    let identity: SenderIdentity
    let spaceTitle: String
    let createTime: Date?
    let text: String
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(
                name: identity.resolvedName,
                photoURL: identity.photoURL,
                size: 26,
                isApp: identity.isApp
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(identity.name)
                        .font(.caption.weight(.semibold))
                    Text(spaceTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let createTime {
                        Text(createTime.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(highlighted)
                    .font(.callout)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
    }

    /// Bolds the matched run so the reason a row appeared is visible at a glance.
    /// Server hits can match on a single word of a longer query, so the first word
    /// that appears is highlighted when the whole query doesn't.
    private var highlighted: AttributedString {
        var attributed = AttributedString(text)
        let candidates = [query] + query.split(whereSeparator: \.isWhitespace).map(String.init)
        for candidate in candidates {
            if let range = attributed.range(of: candidate, options: .caseInsensitive) {
                attributed[range].font = .callout.weight(.bold)
                attributed[range].foregroundColor = .accentColor
                break
            }
        }
        return attributed
    }
}
