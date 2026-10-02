import CoreData
import CloudKit
import Foundation
import OSLog
import CloudKitSyncMonitor
import SwiftData
import SwiftUI

/// Device-local, privacy-safe CloudKit/SwiftData timing telemetry.
@MainActor
final class MovesSyncDiagnostics: ObservableObject {
    enum Stage: String, Codable, Sendable {
        case cloudKitSetup
        case cloudKitImport
        case cloudKitExport
        case localSave
        case localTimelineObservedChange
    }

    enum ErrorDisposition: String, Codable, CaseIterable, Sendable {
        case retryable
        case persistent
        case unknown

        var title: String {
            switch self {
            case .retryable: return "Retryable"
            case .persistent: return "Needs attention"
            case .unknown: return "Unknown"
            }
        }
    }

    struct ErrorDetails: Codable, Equatable, Sendable {
        let stage: Stage
        let disposition: ErrorDisposition
        let domain: String?
        let code: Int?
        let message: String
        let recoverySuggestion: String?
        let occurredAt: Date

        var shortDescription: String {
            "\(disposition.title): \(message)"
        }
    }

    struct Event: Codable, Identifiable {
        let id: UUID
        let stage: Stage
        let startedAt: Date
        let endedAt: Date?
        let succeeded: Bool?
        let errorSummary: String?
        let errorDetails: ErrorDetails?
        let placeCount: Int?
        let moveCount: Int?
        let newestCreatedAt: Date?

        var duration: TimeInterval? {
            guard let endedAt else { return nil }
            return endedAt.timeIntervalSince(startedAt)
        }

        init(
            id: UUID,
            stage: Stage,
            startedAt: Date,
            endedAt: Date?,
            succeeded: Bool?,
            errorSummary: String?,
            placeCount: Int?,
            moveCount: Int?,
            newestCreatedAt: Date?,
            errorDetails: ErrorDetails? = nil
        ) {
            self.id = id
            self.stage = stage
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.succeeded = succeeded
            self.errorSummary = errorSummary
            self.errorDetails = errorDetails
            self.placeCount = placeCount
            self.moveCount = moveCount
            self.newestCreatedAt = newestCreatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, stage, startedAt, endedAt, succeeded, errorSummary, errorDetails
            case placeCount, moveCount, newestCreatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            stage = try container.decode(Stage.self, forKey: .stage)
            startedAt = try container.decode(Date.self, forKey: .startedAt)
            endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
            succeeded = try container.decodeIfPresent(Bool.self, forKey: .succeeded)
            errorSummary = try container.decodeIfPresent(String.self, forKey: .errorSummary)
            errorDetails = try container.decodeIfPresent(ErrorDetails.self, forKey: .errorDetails)
            placeCount = try container.decodeIfPresent(Int.self, forKey: .placeCount)
            moveCount = try container.decodeIfPresent(Int.self, forKey: .moveCount)
            newestCreatedAt = try container.decodeIfPresent(Date.self, forKey: .newestCreatedAt)
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

    var lastErrorDetails: ErrorDetails? {
        events.reversed().compactMap(\.errorDetails).first
    }

    var storeOpenFailure: MovesStoreOpenFailure? {
        MovesStoreRecovery.lastFailure
    }

    static func errorDetails(
        for error: Error,
        stage: Stage,
        occurredAt: Date = .now
    ) -> ErrorDetails {
        let nsError = error as NSError
        let disposition = classify(error)
        return ErrorDetails(
            stage: stage,
            disposition: disposition,
            domain: nsError.domain.isEmpty ? nil : nsError.domain,
            code: nsError.code == 0 ? nil : nsError.code,
            message: privacySafeMessage(error.localizedDescription),
            recoverySuggestion: nsError.localizedRecoverySuggestion.map(privacySafeMessage),
            occurredAt: occurredAt
        )
    }

    static func classify(_ error: Error) -> ErrorDisposition {
        var current: NSError? = error as NSError
        var visited = Set<String>()

        while let candidate = current {
            let identity = "\(candidate.domain):\(candidate.code)"
            guard visited.insert(identity).inserted else { break }

            let urlCode = URLError.Code(rawValue: candidate.code)
            switch urlCode {
            case .cancelled, .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable:
                return .retryable
            default:
                break
            }

            if let cloudKitCode = CKError.Code(rawValue: candidate.code) {
                switch cloudKitCode {
                case .networkUnavailable, .networkFailure, .serviceUnavailable,
                     .requestRateLimited, .zoneBusy, .resultsTruncated, .notAuthenticated:
                    return .retryable
                case .permissionFailure, .constraintViolation,
                     .incompatibleVersion, .badContainer, .badDatabase,
                     .invalidArguments, .quotaExceeded:
                    return .persistent
                default:
                    break
                }
            }

            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return .unknown
    }

    static func privacySafeMessage(_ message: String) -> String {
        var result = message
        let patterns = [
            #"https?://[^\s]+"#,
            #"/(?:Users|private|var|tmp)/[^\s]+"#
        ]
        for pattern in patterns {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = expression.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: "<redacted>"
                )
            }
        }
        return result
    }

    func copyableReport(syncMonitor: SyncMonitor) -> String {
        var lines = [
            "Moves iCloud diagnostics",
            "Generated: \(Date().ISO8601Format())",
            "Container: \(MovesTimelineStore.cloudKitContainerIdentifier)",
            ""
        ]

        let monitorErrors: [(String, Error?)] = [
            ("Setup", syncMonitor.setupError),
            ("Import", syncMonitor.importError),
            ("Export", syncMonitor.exportError)
        ]
        for (name, error) in monitorErrors {
            guard let error else { continue }
            let details = Self.errorDetails(for: error, stage: stage(for: name))
            lines.append("\(name): \(details.disposition.title) — \(details.message) [\(details.domain ?? "unknown")\(details.code.map { ":\($0)" } ?? "")]")
        }

        if monitorErrors.allSatisfy({ $0.1 == nil }), let details = lastErrorDetails {
            lines.append("Last recorded event: \(details.stage.rawValue) — \(details.disposition.title) — \(details.message)")
        }
        if let storeOpenFailure {
            lines.append("Store open: \(storeOpenFailure.disposition.rawValue) — \(storeOpenFailure.message) [\(storeOpenFailure.domain ?? "unknown")\(storeOpenFailure.code.map { ":\($0)" } ?? "")]")
        }
        lines.append("Recorded events: \(events.count)")
        if let snapshot = latestSnapshot {
            lines.append("Local snapshot: \(snapshot.placeCount) places, \(snapshot.moveCount) moves, observed \(snapshot.observedAt.ISO8601Format())")
        }
        lines.append("No coordinates, route points, account identifiers, or location names are included.")
        return lines.joined(separator: "\n")
    }

    func copyableReport() -> String {
        copyableReport(syncMonitor: SyncMonitor.default)
    }

    private func stage(for name: String) -> Stage {
        switch name {
        case "Setup": return .cloudKitSetup
        case "Import": return .cloudKitImport
        default: return .cloudKitExport
        }
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
                errorSummary: event.error.map { Self.privacySafeMessage($0.localizedDescription) },
                placeCount: nil,
                moveCount: nil,
                newestCreatedAt: nil,
                errorDetails: event.error.map {
                    Self.errorDetails(for: $0, stage: stage, occurredAt: event.endDate ?? Date())
                }
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
