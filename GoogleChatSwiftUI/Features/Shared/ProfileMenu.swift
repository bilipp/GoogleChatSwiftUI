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
    let onSignOut: () -> Void
    let onMarkAllRead: () -> Void

    /// Matches the glyph size of a neighbouring toolbar button, so both end up in
    /// glass containers of the same diameter.
    private let avatarSize: CGFloat = 18

    @State private var isPresented = false

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
                    Text(unreadSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)

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

    private var unreadSummary: String {
        totalUnread == 0
            ? "All caught up"
            : "\(totalUnread) unread message\(totalUnread == 1 ? "" : "s")"
    }
}

/// Menu-like row for the account popover, which needs real views rather than the
/// `Button`s a `Menu` would accept.
private struct PanelRow: View {
    let title: String
    let systemImage: String
    var isEnabled: Bool = true
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
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
