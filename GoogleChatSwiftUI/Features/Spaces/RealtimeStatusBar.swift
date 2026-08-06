import SwiftUI

/// Connection state and manual refresh, in one row at the foot of the sidebar.
///
/// Refresh used to be a bare toolbar arrow with no feedback beyond going disabled,
/// while connection state sat separately down here — two scattered halves of the same
/// idea. Together they answer one question: is my list current, and can I make it so?
struct RealtimeStatusBar: View {
    let status: RealtimeCoordinator.Status
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                // Only breathes while something is genuinely in flight; a permanently
                // animating dot reads as a problem.
                .symbolEffectIfAnimating(isAnimating)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .help("Refresh conversations")
            .accessibilityLabel("Refresh conversations")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private var isAnimating: Bool {
        if case .connecting = status { return true }
        return isRefreshing
    }

    private var tint: Color {
        switch status {
        case .live: .green
        case .connecting: .yellow
        case .degraded: .orange
        case .stopped: .secondary
        }
    }

    private var label: String {
        if isRefreshing { return "Refreshing…" }
        switch status {
        case .live: return "Live"
        case .connecting: return "Connecting…"
        case .degraded: return "Reconnecting…"
        case .stopped: return "Offline"
        }
    }
}

private extension View {
    /// Opacity pulse gated on a flag, since `symbolEffect` needs a symbol and this is
    /// a plain shape.
    @ViewBuilder
    func symbolEffectIfAnimating(_ animating: Bool) -> some View {
        if animating {
            self.opacity(0.4)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: animating)
        } else {
            self
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        RealtimeStatusBar(status: .live, isRefreshing: false, onRefresh: {})
        RealtimeStatusBar(status: .connecting, isRefreshing: false, onRefresh: {})
        RealtimeStatusBar(status: .degraded("PERMISSION_DENIED"), isRefreshing: false, onRefresh: {})
        RealtimeStatusBar(status: .live, isRefreshing: true, onRefresh: {})
    }
    .frame(width: 300)
}
