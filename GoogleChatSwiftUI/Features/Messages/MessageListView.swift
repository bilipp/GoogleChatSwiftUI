import SwiftData
import SwiftUI

/// Message history for one space, read from the cache.
///
/// `@Query` is rebuilt per space via `init`, so SwiftData does the filtering and
/// sorting in the store rather than the view loading everything and discarding most.
struct MessageListView: View {
    @Environment(ChatSessionModel.self) private var session
    @Query private var messages: [CachedMessage]

    private let spaceName: String
    private let spaceTitle: String

    init(spaceName: String, spaceTitle: String) {
        self.spaceName = spaceName
        self.spaceTitle = spaceTitle
        _messages = Query(
            filter: #Predicate<CachedMessage> { $0.space?.name == spaceName },
            sort: [SortDescriptor(\CachedMessage.createTime, order: .forward)]
        )
    }

    var body: some View {
        Group {
            if messages.isEmpty {
                if session.isLoading(spaceName) {
                    ProgressView("Loading messages…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Messages",
                        systemImage: "bubble",
                        description: Text("This space has no messages yet.")
                    )
                }
            } else {
                messageScroll
            }
        }
        .navigationTitle(spaceTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.loadOlderMessages(in: spaceName) }
                } label: {
                    Label("Load Older", systemImage: "arrow.up.circle")
                }
                .disabled(session.isLoading(spaceName))
                .help("Fetch older messages")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = session.messageError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
            }
        }
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.isLoading(spaceName) {
                        ProgressView().controlSize(.small).padding(8)
                    }

                    ForEach(groupedByDay, id: \.day) { group in
                        Section {
                            ForEach(Array(group.messages.enumerated()), id: \.element.name) { index, message in
                                MessageRow(
                                    message: message,
                                    // Consecutive messages from one sender read as a
                                    // block, matching how Chat itself groups them.
                                    showsSender: index == 0
                                        || group.messages[index - 1].senderName != message.senderName
                                )
                                .id(message.name)
                            }
                        } header: {
                            DayHeader(day: group.day)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.name, anchor: .bottom) }
            }
        }
    }

    private struct DayGroup {
        let day: Date
        let messages: [CachedMessage]
    }

    /// Written imperatively on purpose: the equivalent chained
    /// `Dictionary(grouping:).map { ... .sorted { ... } }.sorted { ... }` exceeds the
    /// type checker's time budget and fails to compile.
    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        var buckets: [Date: [CachedMessage]] = [:]

        for message in messages {
            let timestamp = message.createTime ?? Date.distantPast
            let day = calendar.startOfDay(for: timestamp)
            buckets[day, default: []].append(message)
        }

        var groups: [DayGroup] = []
        for (day, items) in buckets {
            let ordered = items.sorted { lhs, rhs in
                let left = lhs.createTime ?? Date.distantPast
                let right = rhs.createTime ?? Date.distantPast
                return left < right
            }
            groups.append(DayGroup(day: day, messages: ordered))
        }
        return groups.sorted { $0.day < $1.day }
    }
}

private struct DayHeader: View {
    let day: Date

    var body: some View {
        Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct MessageRow: View {
    let message: CachedMessage
    let showsSender: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsSender {
                HStack(spacing: 6) {
                    Text(message.senderDisplayName ?? "Unknown")
                        .font(.subheadline.weight(.semibold))
                    if let created = message.createTime {
                        Text(created.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }

            Text(message.displayText)
                .font(.body)
                .foregroundStyle(message.isDeleted ? .secondary : .primary)
                .italic(message.isDeleted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
