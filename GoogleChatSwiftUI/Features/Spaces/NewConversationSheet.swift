import SwiftUI

/// Starts a group chat or a named space with the people picked here.
///
/// People come from the directory this app has already resolved — everyone met in a
/// conversation so far — and anyone else can be added by typing their email address,
/// which Chat accepts in place of a user id.
struct NewConversationSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case groupChat = "Group Chat"
        case space = "Space"
        var id: Self { self }
    }

    /// One person picked for the conversation.
    struct Pick: Hashable, Identifiable {
        /// `users/{id}` or `users/{email}`.
        let userName: String
        let displayName: String
        let photoURL: String?
        var id: String { userName }
    }

    @Environment(ChatSessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Called with the new or found conversation once Chat has answered.
    let onCreated: (String) -> Void

    @State private var kind: Kind = .groupChat
    @State private var spaceName = ""
    @State private var spaceDescription = ""
    @State private var query = ""
    @State private var picks: [Pick] = []
    @State private var highlighted = 0
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var focus: Field?

    private enum Field { case name, people }

    private static let suggestionLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Conversation")
                .font(.title3.weight(.semibold))

            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if kind == .space {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Space name", text: $spaceName)
                        .focused($focus, equals: .name)
                    TextField("Description (optional)", text: $spaceDescription, axis: .vertical)
                        .lineLimit(1...3)
                }
                .textFieldStyle(.roundedBorder)
            }

            peopleField

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(createTitle) { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || isWorking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focus = .people }
        .onChange(of: kind) { _, new in
            errorText = nil
            focus = new == .space ? .name : .people
        }
    }

    // MARK: - People

    private var peopleField: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if !picks.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(picks) { pick in chip(for: pick) }
                    }
                }
                TextField("Add people by name or email", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .people)
                    .onSubmit(addHighlighted)
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                    .onKeyPress(.delete) {
                        // Backspace in an empty field takes the last person back out,
                        // as in a mail client's address field.
                        guard query.isEmpty, !picks.isEmpty else { return .ignored }
                        picks.removeLast()
                        return .handled
                    }
                    .onChange(of: query) { _, _ in highlighted = 0 }
            }
            .padding(8)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focus == .people ? Color.accentColor : Color.secondary.opacity(0.35))
            )

            let options = suggestions
            if !options.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        Button { add(option) } label: {
                            suggestionRow(option, isHighlighted: index == highlighted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 4)
            }
        }
    }

    private func chip(for pick: Pick) -> some View {
        HStack(spacing: 4) {
            Avatar(name: pick.displayName, photoURL: pick.photoURL, size: 16)
            Text(pick.displayName)
                .lineLimit(1)
            Button {
                picks.removeAll { $0 == pick }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(pick.displayName)")
        }
        .font(.callout)
        .padding(.leading, 3)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
    }

    private func suggestionRow(_ option: Pick, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            if option.photoURL == nil, option.userName.contains("@") {
                Image(systemName: "envelope")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            } else {
                Avatar(name: option.displayName, photoURL: option.photoURL, size: 22)
            }
            Text(option.displayName)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            isHighlighted ? Color.accentColor.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    /// Directory matches for what is typed, best first, then the typed text itself
    /// when it reads as an email address.
    private var suggestions: [Pick] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }

        let me = session.selfChatName
        let picked = Set(picks.map(\.userName))
        var candidates: [MentionCandidate] = []
        for (id, profile) in session.directory.profiles {
            guard !profile.isApp, id != me, !picked.contains(id),
                  let name = profile.displayName, !name.isEmpty
            else { continue }
            candidates.append(MentionCandidate(userName: id, displayName: name, photoURL: profile.photoURL))
        }
        var result = MentionDirectory.matches(for: needle, in: candidates, limit: Self.suggestionLimit)
            .map { Pick(userName: $0.userName, displayName: $0.displayName, photoURL: $0.photoURL) }

        if Self.looksLikeEmail(needle) {
            let email = needle.lowercased()
            let userName = "users/\(email)"
            if !picked.contains(userName) {
                result.append(Pick(userName: userName, displayName: email, photoURL: nil))
            }
        }
        return result
    }

    private static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !text.contains(where: \.isWhitespace)
    }

    private func moveHighlight(_ delta: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func addHighlighted() {
        let options = suggestions
        guard options.indices.contains(highlighted) else {
            // Return in an empty field means "done", the same as the default button.
            if query.isEmpty, canCreate { create() }
            return
        }
        add(options[highlighted])
    }

    private func add(_ pick: Pick) {
        guard picks.count < ChatClient.maxInitialMembers else {
            errorText = "Chat adds at most \(ChatClient.maxInitialMembers) people when a conversation is created."
            return
        }
        picks.append(pick)
        query = ""
        focus = .people
    }

    // MARK: - Creating

    private var trimmedName: String {
        spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        switch kind {
        case .groupChat: !picks.isEmpty
        case .space: !trimmedName.isEmpty
        }
    }

    private var createTitle: String {
        switch kind {
        case .groupChat: picks.count == 1 ? "Open Chat" : "Start Chat"
        case .space: "Create Space"
        }
    }

    private var hint: String {
        switch kind {
        case .groupChat:
            picks.count == 1
                ? "With one person this opens your direct message with them."
                : "Starting a chat with people you already share one with reopens that chat."
        case .space:
            "A space has a name and can be joined, threaded and managed. People can be added later."
        }
    }

    private func create() {
        guard canCreate, !isWorking else { return }
        isWorking = true
        errorText = nil
        let description = spaceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await session.startConversation(
                named: kind == .space ? trimmedName : nil,
                description: kind == .space && !description.isEmpty ? description : nil,
                members: picks.map(\.userName)
            )
            isWorking = false
            switch result {
            case .success(let spaceName):
                dismiss()
                onCreated(spaceName)
            case .failure(let error):
                errorText = Self.message(for: error)
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let api = error as? ChatAPIError {
            switch api.status {
            case 409: return "A space with that name already exists. Pick another name."
            case 403: return "Chat didn't allow that. \(api.message ?? "")"
            default: break
            }
        }
        return "Couldn't create the conversation. \(error.localizedDescription)"
    }
}
