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

/// Results for a message search, read straight from the cache.
///
/// Local-only by necessity: the Chat API has no message search endpoint at any auth
/// level. That has a consequence worth stating in the UI rather than hiding — search
/// only sees history that has actually been downloaded, and history is fetched lazily
/// per conversation.
struct MessageSearchResults: View {
    @Environment(ChatSessionModel.self) private var session
    @Query private var matches: [CachedMessage]
    @Query private var users: [CachedUser]

    private let query: String

    init(query: String, scopedTo spaceName: String?) {
        self.query = query
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
            if matches.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text(
                        """
                        Nothing found for “\(query)”.
                        Search covers downloaded history only — open a conversation \
                        and scroll to the top to fetch more of it.
                        """
                    )
                }
            } else {
                list
            }
        }
        .navigationTitle("Search")
    }

    private var list: some View {
        List {
            Section {
                ForEach(matches) { message in
                    Button {
                        open(message)
                    } label: {
                        MessageSearchRow(
                            message: message,
                            sender: sender(for: message),
                            query: query
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(countLabel)
            } footer: {
                Text("Only downloaded history is searchable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var countLabel: String {
        matches.count >= 200
            ? "First 200 matches"
            : "\(matches.count) match\(matches.count == 1 ? "" : "es")"
    }

    private var usersByID: [String: CachedUser] {
        Dictionary(users.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func sender(for message: CachedMessage) -> CachedUser? {
        guard let id = message.senderName else { return nil }
        return usersByID[id]
    }

    /// Opens the containing conversation and asks the transcript to jump to the hit.
    private func open(_ message: CachedMessage) {
        guard let space = message.space?.name else { return }
        Task {
            await session.openSpace(space)
            session.scrollTarget = message.name
            session.messageQuery = ""
        }
    }
}

private struct MessageSearchRow: View {
    let message: CachedMessage
    let sender: CachedUser?
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
                    if let created = message.createTime {
                        Text(created.formatted(date: .abbreviated, time: .shortened))
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

    private var identity: SenderIdentity {
        SenderIdentity(message: message, sender: sender)
    }

    private var spaceTitle: String {
        message.space?.title ?? ""
    }

    /// Bolds the matched run so the reason a row appeared is visible at a glance.
    private var highlighted: AttributedString {
        var text = AttributedString(message.summaryText)
        guard let range = text.range(of: query, options: .caseInsensitive) else { return text }
        text[range].font = .callout.weight(.bold)
        text[range].foregroundColor = .accentColor
        return text
    }
}
