import Foundation
import OSLog

/// Subsystem every `Logger` in the app is created under.
///
/// Read from the bundle rather than hard-coded, so changing `PRODUCT_BUNDLE_IDENTIFIER`
/// — which anyone pointing the app at their own Google Cloud project has to do — keeps
/// the logs findable under the identifier they actually shipped.
nonisolated enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "GoogleChatSwiftUI"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
