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
    /// Row count each option would produce, so the menu shows consequences.
    let scopeCounts: [SpaceScope: Int]
    let kindCounts: [SpaceKind: Int]
    let visibleCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Section("Show") {
                    ForEach(SpaceScope.allCases) { option in
                        Button {
                            scope = option
                        } label: {
                            optionLabel(
                                title: option.title,
                                caption: option.caption,
                                count: scopeCounts[option],
                                isSelected: scope == option
                            )
                        }
                    }
                }

                Section("Include") {
                    ForEach(SpaceKind.allCases) { option in
                        Button {
                            kind = option
                        } label: {
                            optionLabel(
                                title: option.title,
                                caption: nil,
                                count: kindCounts[option],
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
        kind == .all ? scope.title : "\(scope.title) · \(kind.shortTitle)"
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
