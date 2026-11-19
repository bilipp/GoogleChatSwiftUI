import SwiftUI

/// `UserDefaults` keys shared between the scenes that read them and the Settings
/// window that writes them.
enum AppSettingsKey {
    static let showMenuBarIcon = "showMenuBarIcon"
}

/// The app's Settings window (⌘,).
///
/// This is the way back once the menu-bar icon is hidden: with the icon gone, the
/// menu it carries is gone too, so the toggle cannot live only there.
struct SettingsView: View {
    @AppStorage(AppSettingsKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some View {
        Form {
            Toggle("Show icon in menu bar", isOn: $showMenuBarIcon)
            Text("The icon lists conversations with unread messages.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
