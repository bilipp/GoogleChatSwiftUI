import Foundation
import SwiftData
import Testing

@testable import GoogleChatSwiftUI

/// Times what one arriving message costs the store in a room that already holds many.
///
/// Not an assertion of a number — timings vary by machine — but a recorded measurement, so
/// a change to the schema or the merge path can be judged against the run before it. The
/// scenario is the one the CPU diagnostics kept pointing at: one `mergeMessages` for one
/// event, in a space with thousands of cached rows. Before the inverse relationships came
/// off `CachedSpace` (see the note there) the seeding alone took the better part of a
/// minute in Debug, because each inserted message materialized every one before it.
///
/// Results go to `build/benchmarks.log` in the checkout when the test can reach it, and to
/// the temporary directory when it cannot — `print` from a hosted test does not reach the
/// `xcodebuild` log. See ``BenchmarkLog``.
struct RelationshipCostBenchmark {
    private func decodeSpace(_ id: String, threaded: Bool) throws -> ChatSpace {
        let state = threaded ? "THREADED_MESSAGES" : "UNTHREADED_MESSAGES"
        let json = """
        {"name":"spaces/\(id)","spaceType":"SPACE","spaceThreadingState":"\(state)","displayName":"Bench"}
        """
        return try GoogleTransport.decoder.decode(ChatSpace.self, from: Data(json.utf8))
    }

    private func decodeMessage(_ index: Int, in space: String, ownThread: Bool) throws -> ChatMessage {
        let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
        let thread = ownThread ? "\(space)/threads/t\(index)" : "\(space)/threads/shared"
        let json = """
        {
          "name":"\(space)/messages/m\(index)",
          "text":"message \(index)",
          "createTime":"\(date.formatted(.iso8601))",
          "sender":{"name":"users/\(index % 40)","type":"HUMAN"},
          "thread":{"name":"\(thread)"},
          "threadReply":false
        }
        """
        return try GoogleTransport.decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func onDiskStore() throws -> (ChatStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: Schema(versionedSchema: ChatSchemaV1.self),
            configurations: ModelConfiguration(url: dir.appending(path: "bench.store"))
        )
        return (ChatStore(modelContainer: container), dir)
    }

    private func run(threaded: Bool, seeded: Int) async throws {
        let (store, dir) = try onDiskStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spaceName = "spaces/B"
        try await store.upsertSpaces([decodeSpace("B", threaded: threaded)])

        let clock = ContinuousClock()
        var index = 0
        let seeding = try await clock.measure {
            while index < seeded {
                var page: [ChatMessage] = []
                for _ in 0..<250 {
                    page.append(try decodeMessage(index, in: spaceName, ownThread: threaded))
                    index += 1
                }
                try await store.appendHistory(page, to: spaceName, nextPageToken: "more")
            }
        }

        var samples: [Duration] = []
        for _ in 0..<8 {
            let message = try decodeMessage(index, in: spaceName, ownThread: threaded)
            index += 1
            samples.append(try await clock.measure {
                try await store.mergeMessages([message], into: spaceName)
            })
        }
        let sorted = samples.map(BenchmarkLog.milliseconds).sorted()
        BenchmarkLog.record(String(
            format: "merge-one threaded=%@ seeded=%d: median %.1f ms, min %.1f ms, max %.1f ms (seeding %.0f ms)",
            threaded ? "yes" : "no", seeded,
            sorted[sorted.count / 2], sorted.first ?? 0, sorted.last ?? 0,
            BenchmarkLog.milliseconds(seeding)
        ))
    }

    @Test func mergeOneIntoUnthreadedRoom() async throws {
        try await run(threaded: false, seeded: 3000)
    }

    @Test func mergeOneIntoThreadedRoom() async throws {
        try await run(threaded: true, seeded: 3000)
    }

    @Test func mergeOneIntoSmallRoom() async throws {
        try await run(threaded: false, seeded: 100)
    }
}

/// Opens a copy of a store written by an earlier build, when one is supplied.
///
/// The schema has changed shape more than once, and one of those changes crashed at store
/// open — so a change to the models is checked against a real cache before it ships, not
/// only against the empty in-memory stores the other tests use. Skipped unless a
/// `default.store` sits in `build/fixture/` in the checkout; the `-wal` and `-shm` files
/// beside it are copied along with it, and the copy is what gets opened, so the fixture is
/// never touched. Found through the source path rather than an environment variable, since
/// `xcodebuild` does not pass those through to a test hosted in the app.
///
/// The test host is sandboxed and cannot read a path outside its container, so run it
/// with the sandbox off:
///
///     mkdir -p build/fixture && cp ~/Library/Containers/<bundle id>/Data/Library/Application\ Support/default.store* build/fixture/
///     xcodebuild test -scheme GoogleChatSwiftUI -destination 'platform=macOS' \
///       -only-testing:GoogleChatSwiftUITests/StoreFixtureTests ENABLE_APP_SANDBOX=NO
struct StoreFixtureTests {
    @Test func opensAndReadsAStoreFromAnEarlierBuild() async throws {
        let fixture = BenchmarkLog.checkout.appending(path: "build/fixture/default.store")
        guard FileManager.default.isReadableFile(atPath: fixture.path) else { return }
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for suffix in ["", "-wal", "-shm"] {
            let source = fixture.deletingLastPathComponent()
                .appending(path: fixture.lastPathComponent + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: dir.appending(path: "default.store\(suffix)"))
        }

        let clock = ContinuousClock()
        var container: ModelContainer?
        let opening = try clock.measure {
            container = try ModelContainer(
                for: Schema(versionedSchema: ChatSchemaV1.self),
                migrationPlan: ChatMigrationPlan.self,
                configurations: ModelConfiguration(url: dir.appending(path: "default.store"))
            )
        }
        let opened = try #require(container)

        // Opened *and migrated*, rather than rebuilt empty: the app's fallback for a failed
        // migration is to delete the cache, which this must not mistake for success.
        let context = ModelContext(opened)
        let spaces = try context.fetchCount(FetchDescriptor<CachedSpace>())
        let messages = try context.fetchCount(FetchDescriptor<CachedMessage>())
        let threads = try context.fetchCount(FetchDescriptor<CachedThread>())
        #expect(spaces > 0)
        #expect(messages > 0)

        // The relationship the transcript and the store query through still resolves.
        var busiest: (name: String, count: Int) = ("", 0)
        for space in try context.fetch(FetchDescriptor<CachedSpace>()) {
            let name = space.name
            let count = try context.fetchCount(TranscriptQueries.allMessages(in: name))
            if count > busiest.count { busiest = (name, count) }
        }
        #expect(busiest.count > 0)
        let window = try context.fetch(TranscriptQueries.window(in: busiest.name, limit: 150))
        #expect(!window.isEmpty)
        #expect(window.allSatisfy { $0.space?.name == busiest.name })

        // And a merge into the busiest room — the operation the diagnostics blamed — is
        // cheap against real data, not only against a store this test seeded itself.
        let store = ChatStore(modelContainer: opened)
        let arriving = try GoogleTransport.decoder.decode(ChatMessage.self, from: Data("""
        {
          "name":"\(busiest.name)/messages/fixture-bench-\(UUID().uuidString)",
          "text":"fixture benchmark",
          "createTime":"\(Date().formatted(.iso8601))",
          "sender":{"name":"users/fixture","type":"HUMAN"},
          "thread":{"name":"\(busiest.name)/threads/fixture-bench"},
          "threadReply":false
        }
        """.utf8))
        let merging = try await clock.measure {
            _ = try await store.mergeIncomingMessage(arriving, into: busiest.name, selfChatName: nil)
        }
        #expect(try context.fetchCount(TranscriptQueries.allMessages(in: busiest.name)) == busiest.count + 1)

        BenchmarkLog.record(String(
            format: "fixture: opened %d spaces / %d messages / %d threads in %.0f ms; merge-one into %@ (%d msgs) %.1f ms",
            spaces, messages, threads, BenchmarkLog.milliseconds(opening),
            busiest.name, busiest.count, BenchmarkLog.milliseconds(merging)
        ))
    }
}

/// Where the benchmarks write what they measured.
enum BenchmarkLog {
    /// The root of the checkout, from this file's own path. Compiled in, so it is right
    /// wherever the tests are built from and needs nothing passed at run time.
    static var checkout: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // GoogleChatSwiftUITests/
            .deletingLastPathComponent()
    }

    /// `build/benchmarks.log` in the checkout, where an unsandboxed run can leave it next
    /// to the other build products; the sandboxed test host cannot write there and falls
    /// back to its own temporary directory.
    static var url: URL {
        let inCheckout = checkout.appending(path: "build/benchmarks.log")
        if FileManager.default.isWritableFile(atPath: inCheckout.deletingLastPathComponent().path) {
            return inCheckout
        }
        return FileManager.default.temporaryDirectory.appending(path: "chat-benchmarks.log")
    }

    static func record(_ line: String) {
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        print("BENCH \(line)")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(stamped.utf8))
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }
}
