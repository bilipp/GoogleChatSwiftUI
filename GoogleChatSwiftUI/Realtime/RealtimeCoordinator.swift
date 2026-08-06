import Foundation
import OSLog

/// Keeps the local cache live: ensures a Workspace Events subscription exists,
/// pulls events from Pub/Sub, applies them, and renews the subscription.
///
/// An actor because it owns the run loop's mutable state and is driven from the
/// main actor by the UI.
actor RealtimeCoordinator {
    enum Status: Sendable, Equatable {
        case stopped
        case connecting
        case live
        case degraded(String)
    }

    private let events: WorkspaceEventsClient
    private let pubsub: PubSubClient
    private let sync: SyncEngine
    private let store: ChatStore
    private let decoder = ChatEventDecoder()
    private let logger = Logger(subsystem: "com.example.GoogleChatSwiftUI", category: "realtime")

    private var runTask: Task<Void, Never>?
    private var renewTask: Task<Void, Never>?
    private var subscriptionName: String?

    private(set) var status: Status = .stopped
    private var statusHandler: (@Sendable (Status) -> Void)?

    /// Pub/Sub synchronous pull often returns immediately when idle, so a short
    /// pause avoids a hot loop. Pull requests are cheap and, unlike polling the Chat
    /// API, cost no Chat quota — so this can stay tight enough to feel instant.
    private static let idlePullInterval: Duration = .seconds(2)

    /// Comfortably inside any plausible subscription TTL. Google's documented maximum
    /// is vague and varies with `includeResource`, so renewal is time-based rather
    /// than derived from the returned expiry.
    private static let renewInterval: Duration = .seconds(30 * 60)

    init(transport: GoogleTransport, sync: SyncEngine, store: ChatStore) {
        events = WorkspaceEventsClient(transport: transport)
        pubsub = PubSubClient(transport: transport)
        self.sync = sync
        self.store = store
    }

    func onStatusChange(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
        handler(status)
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        status = new
        statusHandler?(new)
    }

    // MARK: - Lifecycle

    func start() {
        guard runTask == nil else { return }
        setStatus(.connecting)

        runTask = Task { [weak self] in
            await self?.runLoop()
        }
        renewTask = Task { [weak self] in
            await self?.renewLoop()
        }
    }

    func stop() {
        runTask?.cancel()
        renewTask?.cancel()
        runTask = nil
        renewTask = nil
        setStatus(.stopped)
    }

    // MARK: - Event loop

    private func runLoop() async {
        do {
            let subscription = try await events.ensureSubscription()
            subscriptionName = subscription.name
            setStatus(.live)
        } catch {
            logger.error("Subscription setup failed: \(error.localizedDescription)")
            setStatus(.degraded(error.localizedDescription))
            // Without a subscription there is nothing to pull, but the app remains
            // usable with manual refresh — so this is degraded, not fatal.
            return
        }

        var consecutiveFailures = 0

        while !Task.isCancelled {
            do {
                let received = try await pubsub.pull()
                consecutiveFailures = 0

                if received.isEmpty {
                    try await Task.sleep(for: Self.idlePullInterval)
                    continue
                }

                await apply(received)
                setStatus(.live)
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                logger.error("Pull failed (\(consecutiveFailures)): \(error.localizedDescription)")
                setStatus(.degraded(error.localizedDescription))

                // Back off so a persistent failure does not spin.
                let delay = min(60, pow(2.0, Double(consecutiveFailures)))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func apply(_ received: [PubSubReceivedMessage]) async {
        var ackIds: [String] = []
        var touchedSpaces: Set<String> = []

        for item in received {
            guard let pubsubMessage = item.message else {
                // Unusable envelope; ack it so it stops being redelivered forever.
                if let ackId = item.ackId { ackIds.append(ackId) }
                continue
            }

            if let event = decoder.decode(pubsubMessage) {
                await applyEvent(event, touching: &touchedSpaces)
            }
            // Ack regardless of whether we understood it. An event type this version
            // does not handle would otherwise be redelivered indefinitely.
            if let ackId = item.ackId { ackIds.append(ackId) }
        }

        do {
            // Acked only after the writes above have completed, so a crash mid-apply
            // results in redelivery rather than silent loss.
            try await pubsub.acknowledge(ackIds: ackIds)
        } catch {
            logger.error("Ack failed: \(error.localizedDescription)")
        }

        if !touchedSpaces.isEmpty {
            logger.info("Applied events for \(touchedSpaces.count) space(s)")
        }
    }

    private func applyEvent(_ event: ChatEvent, touching spaces: inout Set<String>) async {
        switch event {
        case .messageCreated(let message), .messageUpdated(let message):
            guard let space = event.spaceName else { return }
            do {
                try await store.mergeMessages([message], into: space)
                // Chat sends an ID with no display name, so an incoming message would
                // otherwise appear as "Unknown" until the next full reload.
                await sync.resolveSenders(from: [message])
                spaces.insert(space)
            } catch {
                logger.error("Merging event message failed: \(error.localizedDescription)")
            }

        case .messageDeleted(let name):
            do {
                try await store.applyDeletion(to: name)
                if let space = event.spaceName { spaces.insert(space) }
            } catch {
                logger.error("Applying deletion failed: \(error.localizedDescription)")
            }

        case .spaceChanged:
            // Space metadata changes are rare and cheap to pick up on next refresh.
            break

        case .unhandled(let type):
            logger.debug("Ignoring unhandled event type \(type)")
        }
    }

    // MARK: - Renewal

    private func renewLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.renewInterval)
            guard !Task.isCancelled, let name = subscriptionName else { continue }
            do {
                _ = try await events.renew(name)
            } catch {
                logger.error("Renewal failed: \(error.localizedDescription)")
                // A subscription that cannot be renewed is likely expired or
                // suspended; re-establish from scratch on the next loop.
                subscriptionName = try? await events.ensureSubscription().name
            }
        }
    }

    // MARK: - Reconciliation

    /// Re-fetches the head of a space.
    ///
    /// The event stream is best-effort, not a durable log. This closes gaps left by
    /// sleep, network loss, or a dropped Pub/Sub message, and is why events are never
    /// treated as the sole source of truth.
    func reconcile(spaceName: String) async {
        do {
            try await sync.reconcileHead(of: spaceName)
        } catch {
            logger.error("Reconcile failed for \(spaceName): \(error.localizedDescription)")
        }
    }
}
