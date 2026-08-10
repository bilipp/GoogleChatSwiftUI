import SwiftUI

/// A sender's avatar: their directory photo, falling back to initials.
///
/// Photos come from the People API — the Chat API supplies none — so a profile that
/// hasn't been resolved yet, or a user outside the directory, degrades to initials
/// rather than a generic silhouette that tells you nothing.
struct Avatar: View {
    /// Nil when nobody knows the sender's name, which is the normal state for an app
    /// and an unresolved one for a person. Either way there are no initials to take.
    let name: String?
    let photoURL: String?
    var size: CGFloat = 28
    /// A Chat app or incoming webhook, which gets a tile instead of a circle.
    var isApp: Bool = false

    var body: some View {
        // Initials sit underneath rather than in a `default` branch of the phase
        // switch, so loading and failure both show them with no extra cases — and,
        // more importantly, the stack always has a correctly sized child. With the
        // image alone, a 96pt Google profile photo drove the layout and the frame
        // below was treated as a suggestion, which is why this rendered oversized.
        ZStack {
            if isApp {
                AppTile(name: name, size: size)
            } else {
                InitialsCircle(name: name, size: size)
            }

            // Through the shared cache rather than `AsyncImage`: the same few hundred
            // faces are drawn by the sidebar, the transcript, the thread list and the
            // search results, and re-decoding one on every scroll is not free. See
            // ``RemoteImage``.
            if let url = photoURL.flatMap(URL.init(string:)) {
                RemoteImage(url: url)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // Clipping removes the hit region outside the shape, which leaves an avatar
        // used as a button or menu label clickable only at its centre.
        .contentShape(shape)
        .accessibilityHidden(true)
    }

    private var shape: AnyShape {
        isApp
            ? AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            : AnyShape(.circle)
    }
}

/// Coloured circle with a person's initials.
struct InitialsCircle: View {
    let name: String?
    var size: CGFloat = 28

    var body: some View {
        Circle()
            .fill(AvatarPalette.color(for: name).gradient)
            .overlay {
                Text(AvatarPalette.initials(for: name))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// Tile for a Chat app or an incoming webhook.
///
/// Not a circle, for the reason ``SpaceIcon`` is not one: the shape says what kind of
/// thing posted before the name has been read, and an automated notification is worth
/// distinguishing from a colleague at a glance.
///
/// Falls back to a glyph rather than to the "?" a person would get, because an unnamed
/// app is the ordinary case rather than a lookup that has not landed — Chat does not
/// hand out app names under user authentication, so the name is whatever the user has
/// typed, if anything.
struct AppTile: View {
    let name: String?
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(AvatarPalette.color(for: name).gradient)
            .overlay {
                if let initials = AvatarPalette.namedInitials(for: name) {
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
    }
}

/// Rounded-square tile for a space.
///
/// Deliberately not a circle: Chat exposes no space avatar, so the shape is the only
/// thing distinguishing "a room" from "a person" at a glance in the sidebar.
struct SpaceIcon: View {
    let title: String
    let symbol: String?
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(AvatarPalette.color(for: title).gradient)
            .frame(width: size, height: size)
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundStyle(.white)
                } else {
                    Text(AvatarPalette.initials(for: title))
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Shared initials and colour derivation, so the same person looks the same
/// everywhere in the app.
enum AvatarPalette {
    static let colors: [Color] = [
        .blue, .purple, .pink, .orange, .green, .teal, .indigo, .brown, .cyan, .mint,
    ]

    /// Initials, or nil when there is no name to take them from — for the callers that
    /// have something better to show than a "?".
    static func namedInitials(for name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let derived = initials(for: name)
        return derived == "?" ? nil : derived
    }

    static func initials(for name: String?) -> String {
        guard let name, !name.isEmpty else { return "?" }
        // Group-chat titles are comma-joined ("Ana, Ben"); use the first person only.
        let primary = name.split(separator: ",").first.map(String.init) ?? name
        let words = primary
            .split(separator: " ")
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
            .prefix(2)
        let letters = words.compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// Deterministic so a given person keeps one colour across launches.
    static func color(for name: String?) -> Color {
        guard let name, !name.isEmpty else { return .gray }
        let hash = name.unicodeScalars.reduce(into: 0) {
            $0 = ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF
        }
        return colors[hash % colors.count]
    }
}

#Preview {
    HStack(spacing: 12) {
        Avatar(name: "Ada Lovelace", photoURL: nil, size: 40)
        InitialsCircle(name: "Ana Silva", size: 40)
        Avatar(name: "Service", photoURL: nil, size: 40, isApp: true)
        Avatar(name: nil, photoURL: nil, size: 40, isApp: true)
        SpaceIcon(title: "Engineering", symbol: nil, size: 40)
        SpaceIcon(title: "Group", symbol: "person.2.fill", size: 40)
    }
    .padding()
}
