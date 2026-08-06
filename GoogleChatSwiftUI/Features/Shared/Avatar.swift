import SwiftUI

/// A person's avatar: their directory photo, falling back to initials.
///
/// Photos come from the People API — the Chat API supplies none — so a profile that
/// hasn't been resolved yet, or a user outside the directory, degrades to initials
/// rather than a generic silhouette that tells you nothing.
struct Avatar: View {
    let name: String?
    let photoURL: String?
    var size: CGFloat = 28

    var body: some View {
        // Initials sit underneath rather than in a `default` branch of the phase
        // switch, so loading and failure both show them with no extra cases — and,
        // more importantly, the stack always has a correctly sized child. With the
        // image alone, a 96pt Google profile photo drove the layout and the frame
        // below was treated as a suggestion, which is why this rendered oversized.
        ZStack {
            InitialsCircle(name: name, size: size)

            if let url = photoURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        // Clipping removes the hit region outside the circle, which leaves an avatar
        // used as a button or menu label clickable only at its centre.
        .contentShape(.circle)
        .accessibilityHidden(true)
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
        Avatar(name: "Philipp Bischoff", photoURL: nil, size: 40)
        InitialsCircle(name: "Ana Silva", size: 40)
        SpaceIcon(title: "Engineering", symbol: nil, size: 40)
        SpaceIcon(title: "Group", symbol: "person.2.fill", size: 40)
    }
    .padding()
}
