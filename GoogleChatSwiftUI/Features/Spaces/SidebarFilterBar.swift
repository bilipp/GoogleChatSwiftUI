import SwiftUI

/// Scope and kind pickers for the conversation list, plus the visible-count readout.
///
/// A `Menu` rather than a segmented control: five icon-only segments gave no clue
/// what any of them did, and the two axes could not be combined at all. Each option
/// carries a caption and a live count, so the effect of choosing it is visible
/// before choosing it.
struct SidebarFilterBar: View {
    @Binding var scope: SpaceScope
    @Binding var kind: SpaceKind
    @Binding var showsMuted: Bool
    /// Muted, unpinned rows behind the toggle. Eager because the button's own title and
    /// this item's enabled state both read it, whether or not the menu is ever opened.
    let mutedCount: Int
    let visibleCount: Int
    /// Row count each option would produce, so the menu shows consequences.
    ///
    /// A closure rather than the numbers themselves: they are read only inside the menu's
    /// content, and counting all seven costs a few milliseconds against the store — see
    /// ``SidebarCounts``. Passing them in would spend that on every pass of a sidebar that
    /// redraws whenever anything is written.
    let counts: () -> SidebarOptionCounts

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                let counted = counts()

                Section("Show") {
                    ForEach(SpaceScope.allCases) { option in
                        Button {
                            scope = option
                        } label: {
                            optionLabel(
                                title: option.title,
                                caption: option.caption,
                                count: counted.scope[option],
                                isSelected: scope == option
                            )
                        }
                    }
                }

                Section("Muted") {
                    Button {
                        showsMuted.toggle()
                    } label: {
                        optionLabel(
                            title: showsMuted ? "Listed at the bottom" : "Hidden",
                            caption: "Conversations you silenced",
                            count: mutedCount,
                            isSelected: showsMuted
                        )
                    }
                    .disabled(mutedCount == 0)
                }

                Section("Include") {
                    ForEach(SpaceKind.allCases) { option in
                        Button {
                            kind = option
                        } label: {
                            optionLabel(
                                title: option.title,
                                caption: nil,
                                count: counted.kind[option],
                                isSelected: kind == option
                            )
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: scope.systemImage)
                        .font(.caption2)
                    Text(buttonTitle)
                        .font(.caption.weight(.medium))
                }
            }
            // Bordered buttons pick up Liquid Glass and the capsule shape from the
            // system on macOS 26; no explicit glass modifier belongs here.
            .buttonStyle(.bordered)
            .controlSize(.small)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Choose which conversations to list")

            Spacer(minLength: 0)

            Text("\(visibleCount)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(visibleCount) conversations listed")
        }
    }

    /// Reflects both axes, but stays short: the kind is only named when it is
    /// actually narrowing anything.
    private var buttonTitle: String {
        var parts = [scope.title]
        if kind != .all { parts.append(kind.shortTitle) }
        // Only surfaced when it changes what is listed, to keep the button short.
        if showsMuted && mutedCount > 0 { parts.append("+muted") }
        return parts.joined(separator: " · ")
    }

    private func optionLabel(
        title: String,
        caption: String?,
        count: Int?,
        isSelected: Bool
    ) -> some View {
        HStack {
            // An explicit checkmark rather than `Picker`: a Menu-styled Picker cannot
            // show per-row captions or counts.
            Image(systemName: isSelected ? "checkmark" : "")
                .frame(width: 12)
            VStack(alignment: .leading) {
                Text(title)
                if let caption {
                    Text(caption).font(.caption)
                }
            }
            if let count {
                Spacer()
                Text("\(count)")
            }
        }
    }
}

/// How many rows each filter option would list.
///
/// A value of its own so the counts can be handed over in one piece from inside the
/// menu's content, where they are worked out — see ``SidebarFilterBar/counts``.
struct SidebarOptionCounts {
    var scope: [SpaceScope: Int] = [:]
    var kind: [SpaceKind: Int] = [:]
}
