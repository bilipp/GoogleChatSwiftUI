import OSLog
import SwiftData
import SwiftUI

@main
struct GoogleChatSwiftUIApp: App {
    @State private var auth = AuthModel()

    /// This store is a pure cache — every row can be re-fetched from Chat. So a
    /// migration failure rebuilds it rather than crashing the app, which would be the
    /// wrong trade for durable user data but is clearly right here.
    private let container: ModelContainer = {
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        do {
            return try ModelContainer(for: schema, migrationPlan: ChatMigrationPlan.self)
        } catch {
            let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "store")
            logger.error("Migration failed, rebuilding cache: \(error.localizedDescription)")

            let url = URL.applicationSupportDirectory.appending(path: "default.store")
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent()
                        .appending(path: "default.store\(suffix)")
                )
            }

            do {
                return try ModelContainer(for: schema, migrationPlan: ChatMigrationPlan.self)
            } catch {
                fatalError("Could not create ModelContainer after rebuild: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .task { await auth.restore() }
        }
        // Wide enough for sidebar + transcript + thread inspector simultaneously;
        // at 1100 the transcript was squeezed to a few words per line once a thread
        // was open.
        .defaultSize(width: 1360, height: 820)
        .modelContainer(container)
    }
}

/// Sits between the app and `ContentView` so the session model can be built once the
/// container and auth state both exist.
private struct RootView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(\.modelContext) private var modelContext
    @State private var session: ChatSessionModel?

    var body: some View {
        Group {
            if case .signedIn = auth.state {
                if let session {
                    ContentView().environment(session)
                } else {
                    ProgressView()
                }
            } else {
                ContentView()
            }
        }
        .onChange(of: isSignedIn, initial: true) { _, signedIn in
            if signedIn {
                if session == nil {
                    session = ChatSessionModel(
                        tokenProvider: auth.tokenProvider,
                        container: modelContext.container,
                        profile: currentProfile
                    )
                }
            } else {
                session = nil
            }
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = auth.state { return true }
        return false
    }

    private var currentProfile: GoogleUserProfile? {
        if case .signedIn(let profile) = auth.state { return profile }
        return nil
    }
}
