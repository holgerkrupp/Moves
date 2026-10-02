import CloudDataPresence
import Combine
import Foundation
import SwiftData

@MainActor
final class MovesCloudDataPresencePublisher: ObservableObject {
    enum PresenceKeys {
        static let moves = "cloudPresence.moves.v1"
        static let places = "cloudPresence.places.v1"
        static let timelineRevision = "cloudPresence.timelineRevision.v1"
    }

    @Published private(set) var timelineFreshness: MovesTimelineFreshnessState = .unknown
    @Published private(set) var remoteTimelineUpdatedAt: Date?
    @Published private(set) var lastPublishedAt: Date?

    private let modelContainer: ModelContainer
    private let keyValueStore: CloudDataPresenceKeyValueStore
    private var pendingPublishTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(
        modelContainer: ModelContainer,
        keyValueStore: CloudDataPresenceKeyValueStore = NSUbiquitousKeyValueStore.default
    ) {
        self.modelContainer = modelContainer
        self.keyValueStore = keyValueStore
        observeChanges()
        refreshRemotePresence()
    }

    deinit {
        pendingPublishTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func publishNow() async {
        pendingPublishTask?.cancel()
        await publishCurrentCounts()
    }

    func publishSoon() {
        pendingPublishTask?.cancel()
        pendingPublishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await self?.publishCurrentCounts()
        }
    }

    private func publishCurrentCounts() async {
        let context = ModelContext(modelContainer)

        do {
            let placeCount = try context.fetchCount(FetchDescriptor<VisitPlace>())
            let moveCount = try context.fetchCount(FetchDescriptor<MoveSegment>())
            let updatedAt = Date()
            let summary = CloudDataPresenceStore.publish(
                recordCountsByKey: [
                    PresenceKeys.places: placeCount,
                    PresenceKeys.moves: moveCount,
                    // A positive sentinel means that an edit which leaves
                    // counts unchanged still advances the freshness marker.
                    PresenceKeys.timelineRevision: 1,
                ],
                updatedAt: updatedAt,
                keyValueStore: keyValueStore
            )
            lastPublishedAt = summary?.updatedAt ?? updatedAt
            remoteTimelineUpdatedAt = lastPublishedAt
            timelineFreshness = .upToDate
        } catch {
            timelineFreshness = .syncError
        }
    }

    private func observeChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .movesTimelineDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publishSoon() }
        })
        for name in [
            Notification.Name.movesLocationSamplesDidChange,
            .movesMoveDataDidChange,
            .movesImportedRouteDataDidChange,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.publishSoon() }
            })
        }
        observers.append(center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: keyValueStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRemotePresence() }
        })
        observers.append(center.addObserver(forName: .movesCloudKitImportObserved, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.timelineFreshness = .upToDate }
        })
    }

    private func refreshRemotePresence() {
        remoteTimelineUpdatedAt = CloudDataPresenceStore.loadReference(
            forKey: PresenceKeys.timelineRevision,
            keyValueStore: keyValueStore
        )?.updatedAt
        updateFreshness()
    }

    private func updateFreshness() {
        guard timelineFreshness != .cloudKitImporting else { return }
        guard let remoteTimelineUpdatedAt else {
            timelineFreshness = .unknown
            return
        }
        if let lastPublishedAt, remoteTimelineUpdatedAt <= lastPublishedAt {
            timelineFreshness = .upToDate
        } else {
            timelineFreshness = .remoteChangesPending
        }
    }
}

enum MovesTimelineFreshnessState: Equatable {
    case unknown
    case upToDate
    case remoteChangesPending
    case cloudKitImporting
    case syncError

    var title: String {
        switch self {
        case .unknown: return "Sync status unknown"
        case .upToDate: return "Timeline is up to date"
        case .remoteChangesPending: return "New timeline data is waiting for iCloud sync"
        case .cloudKitImporting: return "Syncing changes from another device…"
        case .syncError: return "iCloud sync needs attention"
        }
    }
}
