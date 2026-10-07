import CoreData
import CloudKit
import Foundation
import OSLog
import CloudKitSyncMonitor
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum CloudKitFailureAnalysis {
    struct Cause: Codable, Equatable, Sendable {
        let domain: String
        let code: Int
        let count: Int
        let summary: String
    }

    struct Result: Sendable {
        let disposition: MovesSyncDiagnostics.ErrorDisposition
        let message: String
        let recoverySuggestion: String?
        let retryAfterSeconds: TimeInterval?
        let causes: [Cause]
    }

    private struct Finding {
        let error: NSError
        let disposition: MovesSyncDiagnostics.ErrorDisposition
        let summary: String
        let retryAfterSeconds: TimeInterval?
    }

    static func analyze(_ error: Error) -> Result {
        let root = error as NSError
        let findings = leafErrors(in: root).map(finding(for:))
        let effectiveFindings = findings.isEmpty ? [finding(for: root)] : findings
        let disposition = combinedDisposition(effectiveFindings.map(\.disposition))
        let causes = summarizedCauses(effectiveFindings)
        let retryAfter = effectiveFindings.compactMap(\.retryAfterSeconds).max()
        let suggestion = retryAfter.map {
            "Retry after at least \(Int(ceil($0))) seconds."
        } ?? recoverySuggestion(for: disposition, findings: effectiveFindings)
        let message: String
        if root.domain == CKErrorDomain,
           CKError.Code(rawValue: root.code) == .partialFailure,
           !causes.isEmpty {
            let summary = causes.map { cause in
                cause.count == 1 ? cause.summary : "\(cause.count)× \(cause.summary)"
            }.joined(separator: "; ")
            message = "CloudKit reported partial failures: \(summary)"
        } else {
            message = effectiveFindings.first?.summary ?? safe(root.localizedDescription)
        }

        return Result(
            disposition: disposition,
            message: message,
            recoverySuggestion: suggestion,
            retryAfterSeconds: retryAfter,
            causes: causes
        )
    }

    private static func leafErrors(in root: NSError) -> [NSError] {
        var leaves: [NSError] = []
        var queue = [root]
        var visited = Set<ObjectIdentifier>()

        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(ObjectIdentifier(current)).inserted else { continue }

            var children: [NSError] = []
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                children.append(underlying)
            }
            if let multiple = current.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] {
                children.append(contentsOf: multiple)
            }
            if let partial = current.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
                children.append(contentsOf: partial.allValues.compactMap { $0 as? NSError })
            }

            if children.isEmpty {
                leaves.append(current)
            } else {
                queue.append(contentsOf: children)
            }
        }
        return leaves
    }

    private static func finding(for error: NSError) -> Finding {
        let retryAfter = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        guard error.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: error.code) else {
            if error.domain == NSURLErrorDomain {
                let retryable: Set<URLError.Code> = [
                    .cancelled, .timedOut, .cannotConnectToHost, .networkConnectionLost,
                    .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable
                ]
                return Finding(
                    error: error,
                    disposition: retryable.contains(URLError.Code(rawValue: error.code)) ? .retryable : .unknown,
                    summary: safe(error.localizedDescription),
                    retryAfterSeconds: retryAfter
                )
            }
            return Finding(
                error: error,
                disposition: .unknown,
                summary: safe(error.localizedDescription),
                retryAfterSeconds: retryAfter
            )
        }

        let serverDescription = ["CKErrorServerDescription", "ServerErrorDescription"]
            .compactMap { error.userInfo[$0] as? String }
            .first
            .map(safe)
        let localized = safe(error.localizedDescription)
        let genericDescription = localized.contains("CKErrorDomain error \(error.code)")
        let summary: String
        let disposition: MovesSyncDiagnostics.ErrorDisposition

        switch code {
        case .networkUnavailable:
            (disposition, summary) = (.retryable, "The network is unavailable.")
        case .networkFailure:
            (disposition, summary) = (.retryable, "The CloudKit network request failed.")
        case .serviceUnavailable:
            (disposition, summary) = (.retryable, "CloudKit is temporarily unavailable.")
        case .requestRateLimited:
            (disposition, summary) = (.retryable, "CloudKit rate-limited the request.")
        case .zoneBusy:
            (disposition, summary) = (.retryable, "The CloudKit zone is busy.")
        case .resultsTruncated, .serverRecordChanged, .changeTokenExpired, .batchRequestFailed,
             .operationCancelled, .accountTemporarilyUnavailable:
            (disposition, summary) = (.retryable, genericDescription ? readableName(for: code) : localized)
        case .notAuthenticated:
            (disposition, summary) = (.persistent, "iCloud is not signed in or is unavailable for this app.")
        case .permissionFailure:
            (disposition, summary) = (.persistent, "CloudKit denied permission for the request.")
        case .quotaExceeded:
            (disposition, summary) = (.persistent, "The iCloud storage quota is exceeded.")
        case .unknownItem:
            (disposition, summary) = (.persistent, "A required CloudKit record or zone was not found.")
        case .zoneNotFound:
            (disposition, summary) = (.persistent, "The required CloudKit zone is not deployed or available.")
        case .serverRejectedRequest:
            let detail = serverDescription ?? (genericDescription ? nil : localized)
            (disposition, summary) = (
                .persistent,
                detail.map { "CloudKit rejected the request: \($0)" }
                    ?? "CloudKit rejected the request. Verify the deployed Production schema."
            )
        case .constraintViolation, .incompatibleVersion, .badContainer, .badDatabase,
             .invalidArguments, .limitExceeded, .missingEntitlement, .userDeletedZone:
            (disposition, summary) = (.persistent, genericDescription ? readableName(for: code) : localized)
        case .partialFailure:
            (disposition, summary) = (.unknown, "CloudKit reported one or more partial failures.")
        default:
            (disposition, summary) = (.unknown, genericDescription ? readableName(for: code) : localized)
        }

        return Finding(
            error: error,
            disposition: disposition,
            summary: summary,
            retryAfterSeconds: retryAfter
        )
    }

    private static func summarizedCauses(_ findings: [Finding]) -> [Cause] {
        struct Key: Hashable {
            let domain: String
            let code: Int
            let summary: String
        }
        let grouped = Dictionary(grouping: findings) {
            Key(domain: $0.error.domain, code: $0.error.code, summary: $0.summary)
        }
        return grouped.map { key, values in
            Cause(domain: key.domain, code: key.code, count: values.count, summary: key.summary)
        }.sorted {
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            if $0.code != $1.code { return $0.code < $1.code }
            return $0.summary < $1.summary
        }
    }

    private static func combinedDisposition(
        _ dispositions: [MovesSyncDiagnostics.ErrorDisposition]
    ) -> MovesSyncDiagnostics.ErrorDisposition {
        if dispositions.contains(.persistent) { return .persistent }
        if dispositions.allSatisfy({ $0 == .retryable }) { return .retryable }
        return .unknown
    }

    private static func recoverySuggestion(
        for disposition: MovesSyncDiagnostics.ErrorDisposition,
        findings: [Finding]
    ) -> String? {
        if findings.contains(where: {
            $0.error.domain == CKErrorDomain
                && CKError.Code(rawValue: $0.error.code) == .serverRejectedRequest
        }) {
            return "Verify and deploy the required schema in the CloudKit Production environment before releasing."
        }
        if findings.contains(where: {
            $0.error.domain == CKErrorDomain
                && CKError.Code(rawValue: $0.error.code) == .notAuthenticated
        }) {
            return "Check iCloud sign-in and that iCloud Drive is enabled, then retry."
        }
        switch disposition {
        case .retryable: return "Retry after the connection or CloudKit service recovers."
        case .persistent: return "Review the CloudKit account, quota, permissions, and deployed schema."
        case .unknown: return nil
        }
    }

    private static func readableName(for code: CKError.Code) -> String {
        "CloudKit error \(code.rawValue) (\(String(describing: code)))."
    }

    private static func safe(_ message: String) -> String {
        MovesStoreRecovery.privacySafeMessage(message)
    }
}

struct MovesSyncTimelineSnapshot: Equatable, Sendable {
    let observedAt: Date
    let placeCount: Int
    let moveCount: Int
    let newestCreatedAt: Date?
}

actor MovesSyncDiagnosticsSnapshotLoader {
    static let newestFetchLimit = 1

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func load() throws -> MovesSyncTimelineSnapshot {
        try Task.checkCancellation()
        MovesStartupInstrumentation.event("diagnosticsSnapshotQuery")
        let context = ModelContext(modelContainer)
        let placeCount = try context.fetchCount(FetchDescriptor<VisitPlace>())
        try Task.checkCancellation()
        let moveCount = try context.fetchCount(FetchDescriptor<MoveSegment>())
        try Task.checkCancellation()

        var newestPlace = FetchDescriptor<VisitPlace>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        newestPlace.fetchLimit = Self.newestFetchLimit
        let newestPlaceCreatedAt = try context.fetch(newestPlace).first?.createdAt
        try Task.checkCancellation()

        var newestMove = FetchDescriptor<MoveSegment>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        newestMove.fetchLimit = Self.newestFetchLimit
        let newestMoveCreatedAt = try context.fetch(newestMove).first?.createdAt
        try Task.checkCancellation()

        return MovesSyncTimelineSnapshot(
            observedAt: Date(),
            placeCount: placeCount,
            moveCount: moveCount,
            newestCreatedAt: [newestPlaceCreatedAt, newestMoveCreatedAt].compactMap { $0 }.max()
        )
    }
}

/// Device-local, privacy-safe CloudKit/SwiftData timing telemetry.
@MainActor
final class MovesSyncDiagnostics: ObservableObject {
    typealias TimelineSnapshot = MovesSyncTimelineSnapshot
    typealias SnapshotLoader = @Sendable () async throws -> TimelineSnapshot

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
        let retryAfterSeconds: TimeInterval?
        let causes: [CloudKitFailureAnalysis.Cause]?

        init(
            stage: Stage,
            disposition: ErrorDisposition,
            domain: String?,
            code: Int?,
            message: String,
            recoverySuggestion: String?,
            occurredAt: Date,
            retryAfterSeconds: TimeInterval? = nil,
            causes: [CloudKitFailureAnalysis.Cause]? = nil
        ) {
            self.stage = stage
            self.disposition = disposition
            self.domain = domain
            self.code = code
            self.message = message
            self.recoverySuggestion = recoverySuggestion
            self.occurredAt = occurredAt
            self.retryAfterSeconds = retryAfterSeconds
            self.causes = causes
        }

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

    @Published private(set) var events: [Event] = []
    @Published private(set) var latestSnapshot: TimelineSnapshot?

    private static let persistedEventsKey = "Moves.syncDiagnostics.events.v1"
    private static let maxEvents = 120
    private let logger = Logger(subsystem: "de.holgerkrupp.Moves", category: "SyncDiagnostics")
    private let snapshotLoader: SnapshotLoader
    private let observationDebounce: Duration
    private let userDefaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var observationTask: Task<Void, Never>?
    private var observationsEnabled = false
    private var hasInstalledObservers = false

    init(
        modelContainer: ModelContainer,
        observationDebounce: Duration = .milliseconds(350),
        userDefaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        snapshotLoader: SnapshotLoader? = nil
    ) {
        let swiftDataLoader = MovesSyncDiagnosticsSnapshotLoader(modelContainer: modelContainer)
        self.snapshotLoader = snapshotLoader ?? {
            try await swiftDataLoader.load()
        }
        self.observationDebounce = observationDebounce
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
    }

    deinit {
        observationTask?.cancel()
        observers.forEach(notificationCenter.removeObserver)
    }

    /// Starts auxiliary snapshot work after the first interactive Timeline. Calling
    /// this repeatedly is safe and coalesces work.
    func startObservingTimeline() {
        if !hasInstalledObservers {
            hasInstalledObservers = true
            if let data = userDefaults.data(forKey: Self.persistedEventsKey),
               let stored = try? JSONDecoder().decode([Event].self, from: data) {
                events = Array(stored.suffix(Self.maxEvents))
            }
            observeNotifications()
        }
        observationsEnabled = true
        scheduleTimelineObservation(reason: "startup", debounce: false)
    }

    func suspendTimelineObservation() {
        observationsEnabled = false
        observationTask?.cancel()
        observationTask = nil
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

    var coordinationFailure: CrossDeviceWorkCoordinationFailure? {
        CrossDeviceWorkCoordinationHealth.lastFailure
    }

    static func errorDetails(
        for error: Error,
        stage: Stage,
        occurredAt: Date = .now
    ) -> ErrorDetails {
        let nsError = error as NSError
        let analysis = CloudKitFailureAnalysis.analyze(error)
        return ErrorDetails(
            stage: stage,
            disposition: analysis.disposition,
            domain: nsError.domain.isEmpty ? nil : nsError.domain,
            code: nsError.code == 0 ? nil : nsError.code,
            message: analysis.message,
            recoverySuggestion: analysis.recoverySuggestion
                ?? nsError.localizedRecoverySuggestion.map(privacySafeMessage),
            occurredAt: occurredAt,
            retryAfterSeconds: analysis.retryAfterSeconds,
            causes: analysis.causes.isEmpty ? nil : analysis.causes
        )
    }

    static func classify(_ error: Error) -> ErrorDisposition {
        CloudKitFailureAnalysis.analyze(error).disposition
    }

    static func privacySafeMessage(_ message: String) -> String {
        MovesStoreRecovery.privacySafeMessage(message)
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
            let retryAfter = details.retryAfterSeconds.map { " retry-after=\(Int(ceil($0)))s" } ?? ""
            lines.append("\(name): \(details.disposition.title) — \(details.message) [\(details.domain ?? "unknown")\(details.code.map { ":\($0)" } ?? "")\(retryAfter)]")
            for cause in details.causes ?? [] {
                lines.append("  Cause: \(cause.domain):\(cause.code) — \(cause.summary)\(cause.count > 1 ? " (×\(cause.count))" : "")")
            }
        }

        if monitorErrors.allSatisfy({ $0.1 == nil }), let details = lastErrorDetails {
            lines.append("Last recorded event: \(details.stage.rawValue) — \(details.disposition.title) — \(details.message)")
        }
        if let storeOpenFailure {
            lines.append("Store open: \(storeOpenFailure.disposition.rawValue) — \(storeOpenFailure.message) [\(storeOpenFailure.domain ?? "unknown")\(storeOpenFailure.code.map { ":\($0)" } ?? "")]")
        }
        if let coordinationFailure {
            lines.append("Background coordination (\(coordinationFailure.operation)): \(coordinationFailure.disposition.title) — \(coordinationFailure.message)")
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
        let center = notificationCenter
        observers.append(center.addObserver(
            forName: .movesWorkCoordinationHealthDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        })
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
                    self?.scheduleTimelineObservation(reason: "authoritative-change")
                }
            })
        }

        observers.append(center.addObserver(
            forName: .movesCloudKitImportObserved,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleTimelineObservation(reason: "cloud-import")
            }
        })

        #if canImport(UIKit)
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.suspendTimelineObservation()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.startObservingTimeline()
            }
        })
        #elseif canImport(AppKit)
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.suspendTimelineObservation()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.startObservingTimeline()
            }
        })
        #endif
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
        let details = event.error.map {
            Self.errorDetails(for: $0, stage: stage, occurredAt: event.endDate ?? Date())
        }
        append(
            Event(
                id: UUID(),
                stage: stage,
                startedAt: startedAt,
                endedAt: event.endDate,
                succeeded: event.endDate.map { _ in event.succeeded },
                errorSummary: details?.shortDescription,
                placeCount: nil,
                moveCount: nil,
                newestCreatedAt: nil,
                errorDetails: details
            )
        )

        if stage == .cloudKitImport, event.endDate != nil, event.succeeded {
            notificationCenter.post(name: .movesCloudKitImportObserved, object: nil)
        }
    }

    private func scheduleTimelineObservation(reason: String, debounce: Bool = true) {
        guard observationsEnabled else { return }
        observationTask?.cancel()

        let delay = debounce ? observationDebounce : .zero
        let loader = snapshotLoader
        observationTask = Task(priority: .utility) { [weak self] in
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                try Task.checkCancellation()
                let snapshot = try await loader()
                try Task.checkCancellation()
                guard let self, self.observationsEnabled else { return }
                self.record(snapshot: snapshot, reason: reason)
                self.observationTask = nil
            } catch is CancellationError {
                // A newer notification or app suspension superseded this work.
            } catch {
                guard let self else { return }
                self.observationTask = nil
                let safeMessage = Self.privacySafeMessage(error.localizedDescription)
                self.logger.error("Timeline observation failed: \(safeMessage, privacy: .public)")
            }
        }
    }

    private func record(snapshot: TimelineSnapshot, reason: String) {
        latestSnapshot = snapshot
        append(
            Event(
                id: UUID(),
                stage: reason == "authoritative-change" ? .localSave : .localTimelineObservedChange,
                startedAt: snapshot.observedAt,
                endedAt: snapshot.observedAt,
                succeeded: true,
                errorSummary: nil,
                placeCount: snapshot.placeCount,
                moveCount: snapshot.moveCount,
                newestCreatedAt: snapshot.newestCreatedAt
            )
        )
    }

    private func append(_ event: Event) {
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        if let data = try? JSONEncoder().encode(events) {
            userDefaults.set(data, forKey: Self.persistedEventsKey)
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
