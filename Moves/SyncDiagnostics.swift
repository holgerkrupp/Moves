import CoreData
import Foundation
import OSLog
import SwiftData
import SwiftUI

/// Device-local, privacy-safe CloudKit/SwiftData timing telemetry.
@MainActor
final class MovesSyncDiagnostics: ObservableObject {
    enum Stage: String, Codable {
        case cloudKitSetup
        case cloudKitImport
        case cloudKitExport
        case localSave
        case localTimelineObservedChange
    }

    struct Event: Codable, Identifiable {
        let id: UUID
        let stage: Stage
        let startedAt: Date
        let endedAt: Date?
        let succeeded: Bool?
        let errorSummary: String?
        let placeCount: Int?
        let moveCount: Int?
        let newestCreatedAt: Date?

        var duration: TimeInterval? {
            guard let endedAt else { return nil }
            return endedAt.timeIntervalSince(startedAt)
        }
    }

    struct TimelineSnapshot: Equatable {
        let observedAt: Date
        let placeCount: Int
        let moveCount: Int
        let newestCreatedAt: Date?
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var latestSnapshot: TimelineSnapshot?

    private static let persistedEventsKey = "Moves.syncDiagnostics.events.v1"
    private static let maxEvents = 120
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "de.holgerkrupp.Moves", category: "SyncDiagnostics")
    private var observers: [NSObjectProtocol] = []

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        if let data = UserDefaults.standard.data(forKey: Self.persistedEventsKey),
           let stored = try? JSONDecoder().decode([Event].self, from: data) {
            events = Array(stored.suffix(Self.maxEvents))
        }
        observeNotifications()
        observeTimeline(reason: "startup")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var lastSuccessfulImport: Event? {
        events.last { $0.stage == .cloudKitImport && $0.succeeded == true }
    }

    var lastSuccessfulExport: Event? {
        events.last { $0.stage == .cloudKitExport && $0.succeeded == true }
    }

    var lastError: Event? {
        events.reversed().first { $0.errorSummary != nil }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in
                self.recordCloudKitEvent(event)
            }
        })

        for name in [
            Notification.Name.movesTimelineDidChange,
            .movesLocationSamplesDidChange,
            .movesMoveDataDidChange,
            .movesImportedRouteDataDidChange,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.observeTimeline(reason: "authoritative-change")
                }
            })
        }

        observers.append(center.addObserver(
            forName: .movesCloudKitImportObserved,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.observeTimeline(reason: "cloud-import")
            }
        })
    }

    private func recordCloudKitEvent(_ event: NSPersistentCloudKitContainer.Event) {
        let stage: Stage
        switch event.type {
        case .setup: stage = .cloudKitSetup
        case .import: stage = .cloudKitImport
        case .export: stage = .cloudKitExport
        @unknown default: return
        }

        let startedAt = event.startDate
        append(
            Event(
                id: UUID(),
                stage: stage,
                startedAt: startedAt,
                endedAt: event.endDate,
                succeeded: event.endDate.map { _ in event.succeeded },
                errorSummary: event.error?.localizedDescription,
                placeCount: nil,
                moveCount: nil,
                newestCreatedAt: nil
            )
        )

        if stage == .cloudKitImport, event.endDate != nil, event.succeeded {
            NotificationCenter.default.post(name: .movesCloudKitImportObserved, object: nil)
        }
    }

    private func observeTimeline(reason: String) {
        let context = ModelContext(modelContainer)
        do {
            let placeCount = try context.fetchCount(FetchDescriptor<VisitPlace>())
            let moveCount = try context.fetchCount(FetchDescriptor<MoveSegment>())
            let places = try context.fetch(FetchDescriptor<VisitPlace>())
            let moves = try context.fetch(FetchDescriptor<MoveSegment>())
            let newestCreatedAt = (places.map(\.createdAt) + moves.map(\.createdAt)).max()
            let observedAt = Date()
            latestSnapshot = TimelineSnapshot(
                observedAt: observedAt,
                placeCount: placeCount,
                moveCount: moveCount,
                newestCreatedAt: newestCreatedAt
            )
            append(
                Event(
                    id: UUID(),
                    stage: reason == "authoritative-change" ? .localSave : .localTimelineObservedChange,
                    startedAt: observedAt,
                    endedAt: observedAt,
                    succeeded: true,
                    errorSummary: nil,
                    placeCount: placeCount,
                    moveCount: moveCount,
                    newestCreatedAt: newestCreatedAt
                )
            )
        } catch {
            logger.error("Timeline observation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func append(_ event: Event) {
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: Self.persistedEventsKey)
        }
        logger.log("sync stage=\(event.stage.rawValue, privacy: .public)")
        objectWillChange.send()
    }
}

struct MovesSyncDiagnosticsCard: View {
    @EnvironmentObject private var diagnostics: MovesSyncDiagnostics
    @EnvironmentObject private var presence: MovesCloudDataPresencePublisher

    private static let dateStyle = Date.FormatStyle.dateTime
        .month(.abbreviated)
        .day()
        .hour()
        .minute()

    var body: some View {
        GroupBox("Sync diagnostics") {
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("Timeline", value: presence.timelineFreshness.title)
                LabeledContent("Last export", value: formatted(diagnostics.lastSuccessfulExport?.endedAt))
                LabeledContent("Last import", value: formatted(diagnostics.lastSuccessfulImport?.endedAt))
                if let snapshot = diagnostics.latestSnapshot {
                    LabeledContent(
                        "Observed",
                        value: "\(snapshot.placeCount) places · \(snapshot.moveCount) moves · \(formatted(snapshot.observedAt))"
                    )
                }
                if let error = diagnostics.lastError?.errorSummary {
                    Text("Last error: \(error)")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Text("Diagnostics are device-local and contain counts/timestamps only; no coordinates or location text is recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatted(_ date: Date?) -> String {
        date.map { $0.formatted(Self.dateStyle) } ?? "Not recorded"
    }
}
