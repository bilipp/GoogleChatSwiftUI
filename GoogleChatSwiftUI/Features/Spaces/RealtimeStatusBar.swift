import SwiftUI

/// Shows whether the live event stream is actually working.
///
/// Worth the space: a silently dead subscription looks identical to a quiet
/// workday, and the user would have no way to tell that messages had stopped
/// arriving until something important was missed.
struct RealtimeStatusBar: View {
    let status: RealtimeCoordinator.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(label)")
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
        switch status {
        case .live: "Live"
        case .connecting: "Connecting…"
        case .degraded: "Reconnecting…"
        case .stopped: "Offline"
        }
    }

    private var helpText: String {
        switch status {
        case .live: "Receiving messages in real time."
        case .connecting: "Setting up the event subscription."
        case .degraded(let reason): "Live updates interrupted: \(reason)"
        case .stopped: "Live updates are not running."
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        RealtimeStatusBar(status: .live)
        RealtimeStatusBar(status: .connecting)
        RealtimeStatusBar(status: .degraded("PERMISSION_DENIED on topic"))
        RealtimeStatusBar(status: .stopped)
    }
    .frame(width: 280)
}
