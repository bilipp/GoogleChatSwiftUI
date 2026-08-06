import SwiftData
import SwiftUI

@main
struct GoogleChatSwiftUIApp: App {
    @State private var auth = AuthModel()

    private let container: ModelContainer = {
        do {
            let schema = Schema(versionedSchema: ChatSchemaV1.self)
            return try ModelContainer(for: schema, migrationPlan: ChatMigrationPlan.self)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .task { await auth.restore() }
        }
        .defaultSize(width: 1100, height: 720)
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
                        container: modelContext.container
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
}
