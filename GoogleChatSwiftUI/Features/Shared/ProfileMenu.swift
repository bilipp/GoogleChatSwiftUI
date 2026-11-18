import SwiftUI

/// Account control behind the signed-in user's avatar, top right.
///
/// A `Button` with a popover rather than a `Menu`. A `Menu` on macOS refuses to be
/// constrained when its label is an image: it laid the avatar out at the photo's own
/// size, ignored the frame, dropped the circular clip, and left a stray indicator
/// glyph beside it. A button gives exact control over size and hit area, and the
/// popover can show the account properly instead of as a bare text row.
struct ProfileMenu: View {
    let profile: GoogleUserProfile?
    let totalUnread: Int
    /// The user's own presence and custom status; nil hides the status section.
    var availability: ChatAvailability? = nil
    var onSetAvailability: (AvailabilityChange) -> Void = { _ in }
    /// Called each time the popover opens, to refresh `availability`.
    var onOpen: () -> Void = {}
    let onSignOut: () -> Void
    let onMarkAllRead: () -> Void

    /// Matches the glyph size of a neighbouring toolbar button, so both end up in
    /// glass containers of the same diameter.
    private let avatarSize: CGFloat = 18

    @State private var isPresented = false
    @State private var statusDraft = ""

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Avatar(
                name: profile?.displayName,
                // `GoogleUserProfile` holds a URL; `Avatar` takes the string form
                // used by cached directory profiles.
                photoURL: profile?.photoURL?.absoluteString,
                size: avatarSize
            )
            .overlay(alignment: .bottomTrailing) {
                // Only the states someone would want reminding of. A green dot for
                // the ordinary case would just be noise on every window.
                if let state = availability?.state, state == .doNotDisturb || state == .away {
                    PresenceDot(state: state, size: 7)
                        .offset(x: 2, y: 2)
                }
            }
        }
        // The toolbar derives a control's glass container shape from its content: an
        // SF Symbol gets a circle, an arbitrary view like this one gets a rounded
        // rectangle. That left a round avatar sitting inside a squarish container.
        // `buttonBorderShape(.circle)` states the shape outright, so the container is
        // concentric with the avatar and matches the adjacent toolbar buttons.
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(profile?.displayName ?? "Account")
        .accessibilityLabel("Account: \(profile?.displayName ?? "signed in")")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            accountPanel
        }
        .onChange(of: isPresented) { _, presented in
            guard presented else { return }
            statusDraft = availability?.visibleCustomStatus?.text ?? ""
            onOpen()
        }
    }

    private var accountPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Avatar(
                    name: profile?.displayName,
                    photoURL: profile?.photoURL?.absoluteString,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile?.displayName ?? "Signed in")
                        .font(.headline)
                    if let availability {
                        HStack(spacing: 4) {
                            PresenceDot(state: availability.state ?? .unspecified, size: 7)
                            Text(presenceSummary(availability))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text(unreadSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)

            if availability != nil {
                Divider()
                statusSection
            }

            Divider()

            VStack(spacing: 0) {
                PanelRow(
                    title: "Mark All as Read",
                    systemImage: "checkmark.circle",
                    isEnabled: totalUnread > 0
                ) {
                    isPresented = false
                    onMarkAllRead()
                }

                PanelRow(
                    title: "Sign Out",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isDestructive: true
                ) {
                    isPresented = false
                    onSignOut()
                }
            }
            .padding(6)
        }
        .frame(width: 260)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let emoji = availability?.visibleCustomStatus?.emoji?.unicode, !emoji.isEmpty {
                    Text(emoji)
                }
                TextField("What’s your status?", text: $statusDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitStatus)
                if availability?.visibleCustomStatus != nil {
                    Button {
                        statusDraft = ""
                        onSetAvailability(.customStatus(text: nil, emoji: nil, until: nil))
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear status")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            PanelRow(
                title: "Active",
                systemImage: "circle.fill",
                tint: .green,
                isChecked: isState(.active, .idle)
            ) { onSetAvailability(.active) }

            PanelRow(
                title: "Away",
                systemImage: "circle.fill",
                tint: .orange,
                isChecked: isState(.away)
            ) { onSetAvailability(.away) }

            PanelRow(
                title: "Do Not Disturb for 1 Hour",
                systemImage: "minus.circle.fill",
                tint: .red,
                isChecked: false
            ) { onSetAvailability(.doNotDisturb(until: .now.addingTimeInterval(3600))) }

            PanelRow(
                title: "Do Not Disturb Until Tomorrow",
                systemImage: "minus.circle.fill",
                tint: .red,
                isChecked: false
            ) { onSetAvailability(.doNotDisturb(until: Self.tomorrowMorning)) }
        }
        .padding(6)
    }

    private func isState(_ states: ChatAvailability.State...) -> Bool {
        guard let state = availability?.state else { return false }
        return states.contains(state)
    }

    private func commitStatus() {
        let text = statusDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = availability?.visibleCustomStatus?.text ?? ""
        guard text != current else { return }
        // A typed status keeps the emoji already set; an empty field clears both.
        let emoji = text.isEmpty ? nil : availability?.visibleCustomStatus?.emoji?.unicode
        onSetAvailability(.customStatus(text: text.isEmpty ? nil : text, emoji: emoji, until: nil))
    }

    private func presenceSummary(_ availability: ChatAvailability) -> String {
        let custom = availability.visibleCustomStatus?.text.flatMap { $0.isEmpty ? nil : $0 }
        let presence: String
        switch availability.state ?? .unspecified {
        case .active: presence = "Active"
        case .idle: presence = "Idle"
        case .away: presence = "Away"
        case .doNotDisturb:
            if let end = availability.expireTime {
                presence = "Do not disturb until \(end.formatted(date: Calendar.current.isDateInToday(end) ? .omitted : .abbreviated, time: .shortened))"
            } else {
                presence = "Do not disturb"
            }
        case .unspecified: presence = "Status unknown"
        }
        return custom.map { "\(presence) · \($0)" } ?? presence
    }

    /// 08:00 the next day, when "until tomorrow" would reasonably end.
    private static var tomorrowMorning: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private var unreadSummary: String {
        totalUnread == 0
            ? "All caught up"
            : "\(totalUnread) unread message\(totalUnread == 1 ? "" : "s")"
    }
}

/// The account control as a toolbar item's content, reading what it shows from the
/// environment.
///
/// It exists so every detail state can place the control itself, as the last item of
/// its own toolbar. Toolbar order is not declaration order across views: items
/// contributed by the split view as a whole are laid out before the detail column's
/// own, so an account control declared up there lands to the *left* of the
/// transcript's buttons no matter which placement it asks for. Declared alongside
/// them, in one toolbar, it follows them.
struct AccountToolbarButton: View {
    @Environment(AuthModel.self) private var auth
    @Environment(ChatSessionModel.self) private var session

    var body: some View {
        ProfileMenu(
            profile: profile,
            totalUnread: session.totalUnread,
            availability: session.availability,
            onSetAvailability: { change in Task { await session.setAvailability(change) } },
            onOpen: { Task { await session.loadAvailability() } },
            onSignOut: { Task { await auth.signOut() } },
            onMarkAllRead: { Task { await session.markAllRead() } }
        )
    }

    private var profile: GoogleUserProfile? {
        if case .signedIn(let profile) = auth.state { return profile }
        return nil
    }
}

/// Menu-like row for the account popover, which needs real views rather than the
/// `Button`s a `Menu` would accept.
private struct PanelRow: View {
    let title: String
    let systemImage: String
    var tint: Color? = nil
    /// Non-nil turns the row into a choice, with a checkmark when selected.
    var isChecked: Bool? = nil
    var isEnabled: Bool = true
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .imageScale(tint == nil ? .medium : .small)
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
                if isChecked == true {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            // Hover fill has to come from a background rather than a button style:
            // `.plain` draws none, and a bordered style would box every row.
            .background(
                isHovering && isEnabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: 5)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
    }
}

/// Coloured presence marker, matching the colours Chat itself uses.
private struct PresenceDot: View {
    let state: ChatAvailability.State
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
    }

    private var color: Color {
        switch state {
        case .active: .green
        case .idle, .away: .orange
        case .doNotDisturb: .red
        case .unspecified: .secondary
        }
    }
}
