import SwiftUI

/// One reaction chip as the sheet's emoji switcher draws it: what it is and how many
/// the transcript last counted.
///
/// A plain value rather than the `CachedReaction` it comes from, because the sheet
/// outlives the row that opened it — a sync landing mid-read must not mutate the tabs
/// under the cursor, or delete the model the sheet is holding.
nonisolated struct ReactionSummary: Sendable, Hashable, Identifiable {
    let emoji: String
    let count: Int

    var id: String { emoji }
}

/// Who reacted to a message, as a modal.
///
/// Loaded when it opens rather than with the message: Chat reports reaction counts on
/// every message but names nobody, so putting faces to a chip costs a listing call that
/// only matters while someone is actually asking. That one call covers every emoji on
/// the message, which is why switching tabs here is instant.
struct ReactorSheet: View {
    @Environment(ChatSessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let messageName: String
    /// Every chip on the message, in the order the transcript drew them.
    let reactions: [ReactionSummary]
    /// The chip that was right-clicked, selected when the sheet opens.
    let initialEmoji: String

    private enum LoadState {
        case loading
        case loaded([String: [Reactor]])
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var selected: String

    init(messageName: String, reactions: [ReactionSummary], initialEmoji: String) {
        self.messageName = messageName
        self.reactions = reactions
        self.initialEmoji = initialEmoji
        _selected = State(initialValue: initialEmoji)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabs
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 420, height: 460)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Text("Reactions")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    /// One tab per emoji on the message, so a reader who opened the wrong chip does not
    /// have to close this and right-click again.
    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(reactions) { reaction in
                    tab(for: reaction)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }

    private func tab(for reaction: ReactionSummary) -> some View {
        let isSelected = reaction.emoji == selected
        return Button {
            selected = reaction.emoji
        } label: {
            HStack(spacing: 4) {
                Text(reaction.emoji)
                Text("\(count(for: reaction))")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                           : AnyShapeStyle(.quaternary),
                in: .capsule
            )
            .overlay {
                if isSelected {
                    Capsule().strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(reaction.emoji), \(count(for: reaction)) reactions")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The loaded count wins once there is one: the cached chip can be a refresh behind.
    private func count(for reaction: ReactionSummary) -> Int {
        if case .loaded(let groups) = state, let group = groups[reaction.emoji] {
            return group.count
        }
        return reaction.count
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            centred {
                ProgressView()
                    .controlSize(.small)
            }

        case .loaded(let groups):
            let reactors = groups[selected] ?? []
            if reactors.isEmpty {
                // Reached when the last reaction of this kind was removed between the
                // chip being drawn and this being opened.
                centred {
                    Text("Nobody has reacted with \(selected).")
                        .foregroundStyle(.secondary)
                }
            } else {
                List(reactors) { reactor in
                    row(for: reactor)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
            }

        case .failed(let message):
            centred {
                VStack(spacing: 8) {
                    Text("Couldn't load who reacted.")
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        state = .loading
                        Task { await load() }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for reactor: Reactor) -> some View {
        HStack(spacing: 8) {
            Avatar(
                name: reactor.displayName,
                photoURL: reactor.photoURL,
                size: 28,
                isApp: reactor.isApp
            )
            Text(reactor.label)
                .foregroundStyle(reactor.displayName == nil && !reactor.isSelf ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            state = .loaded(try await session.reactors(on: messageName))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
