import Foundation
import CoreLocation
import HealthKit
import SwiftData
import UIKit

struct HealthWorkoutRouteImportReport {
    let workoutCount: Int
    let routeCount: Int
    let sampleCount: Int
    let didResumeInterruptedImport: Bool
}

private enum HealthWorkoutRouteImportError: LocalizedError {
    case backgroundTimeExpired

    var errorDescription: String? {
        switch self {
        case .backgroundTimeExpired:
            return "iOS paused the Health import before it could finish. Progress was saved and the next historical import will continue from the last checked workout."
        }
    }
}

enum HealthWorkoutRouteImportSettings {
    static let isEnabledKey = "Moves.healthWorkoutRouteImport.isEnabled"
    static let lastAutomaticImportAtKey = "Moves.healthWorkoutRouteImport.lastAutomaticImportAt"
    static let didChangeNotification = Notification.Name("Moves.healthWorkoutRouteImport.didChange")

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    static var lastAutomaticImportAt: Date? {
        get { UserDefaults.standard.object(forKey: lastAutomaticImportAtKey) as? Date }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: lastAutomaticImportAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastAutomaticImportAtKey)
            }
        }
    }
}

private enum ImportScope: String, Codable {
    case allHistorical
    case recent
}

private struct PersistedHealthWorkoutRouteImportState: Codable {
    var scope: ImportScope
    var startDate: Date?
    var nextEndDate: Date?
    var importedWorkoutCount: Int
    var importedRouteCount: Int
    var importedSampleCount: Int
    var updatedAt: Date
}

@MainActor
final class HealthWorkoutRouteImporter: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: Double?
    @Published private(set) var importProgressText = ""
    @Published private(set) var lastReport: HealthWorkoutRouteImportReport?
    @Published private(set) var lastErrorMessage: String?

    private let modelContainer: ModelContainer
    private let progressDidChange: ((String) -> Void)?
    private var shouldStopImport = false

    init(modelContext: ModelContext, progressDidChange: ((String) -> Void)? = nil) {
        self.modelContainer = modelContext.container
        self.progressDidChange = progressDidChange
    }

    init(modelContainer: ModelContainer, progressDidChange: ((String) -> Void)? = nil) {
        self.modelContainer = modelContainer
        self.progressDidChange = progressDidChange
    }

    static var hasInterruptedHistoricalImport: Bool {
        persistedState(matching: .allHistorical, startDate: nil) != nil
    }

    nonisolated private static let persistedStateKey = "Moves.healthWorkoutRouteImport.persistedState"

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func importRecentWorkoutRoutes(daysBack: Int = 30) async {
        let startDate = Calendar.current.date(
            byAdding: .day,
            value: -daysBack,
            to: .now
        ) ?? .now.addingTimeInterval(-TimeInterval(daysBack * 24 * 60 * 60))

        await importWorkoutRoutes(
            startingAt: startDate,
            scope: .recent,
            resumesInterruptedImport: false
        )
    }

    func importAllWorkoutRoutes() async {
        await importWorkoutRoutes(
            startingAt: nil,
            scope: .allHistorical,
            resumesInterruptedImport: true
        )
    }

    func cancelImport() {
        shouldStopImport = true
        updateProgressText("Pausing import...")
    }

    private func importWorkoutRoutes(
        startingAt startDate: Date?,
        scope: ImportScope,
        resumesInterruptedImport: Bool
    ) async {
        guard !isImporting else { return }
        guard isAvailable else {
            lastErrorMessage = "Health data is not available on this device."
            return
        }

        isImporting = true
        shouldStopImport = false
        importProgress = nil
        updateProgressText("Preparing import...")
        let backgroundTask = beginBackgroundTask()
        defer {
            endBackgroundTask(backgroundTask)
            isImporting = false
            shouldStopImport = false
            importProgress = nil
            updateProgressText("")
        }

        do {
            let importer = self
            let worker = HealthWorkoutRouteImportWorker(
                modelContainer: modelContainer,
                shouldStop: {
                    await MainActor.run { importer.shouldStopImport }
                },
                progress: { text in
                    await MainActor.run {
                        importer.updateProgressText(text)
                    }
                }
            )
            let report = try await worker.importWorkoutRoutes(
                startingAt: startDate,
                scope: scope,
                resumesInterruptedImport: resumesInterruptedImport
            )
            lastReport = report
            lastErrorMessage = nil
            if report.workoutCount == 0 {
                updateProgressText("No supported workouts found.")
            }
        } catch is CancellationError {
            lastErrorMessage = "Import paused. Progress was saved and the next import will resume from the last checked workout."
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func updateProgressText(_ text: String) {
        importProgressText = text
        progressDidChange?(text)
    }

    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "Apple Health route import") { [weak self] in
            Task { @MainActor in
                self?.shouldStopImport = true
            }
        }
    }

    private func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }

}

private actor HealthWorkoutRouteImportWorker {
    private let healthStore = HKHealthStore()
    private let modelContainer: ModelContainer
    private let shouldStop: @Sendable () async -> Bool
    private let progress: @Sendable (String) async -> Void
    private let workoutBatchLimit = 40
    private let maximumImportedRouteLocationCount = 30_000

    init(
        modelContainer: ModelContainer,
        shouldStop: @escaping @Sendable () async -> Bool,
        progress: @escaping @Sendable (String) async -> Void
    ) {
        self.modelContainer = modelContainer
        self.shouldStop = shouldStop
        self.progress = progress
    }

    func importWorkoutRoutes(
        startingAt startDate: Date?,
        scope: ImportScope,
        resumesInterruptedImport: Bool
    ) async throws -> HealthWorkoutRouteImportReport {
        try await requestAuthorizationIfNeeded()

        let persistedState = resumesInterruptedImport
            ? HealthWorkoutRouteImporter.persistedState(matching: scope, startDate: startDate)
            : nil
        var importedRouteCount = persistedState?.importedRouteCount ?? 0
        var importedSampleCount = persistedState?.importedSampleCount ?? 0
        var importedWorkoutCount = persistedState?.importedWorkoutCount ?? 0
        var cursorEndDate = persistedState?.nextEndDate
        await progress(persistedState == nil ? "Preparing import..." : "Resuming saved import...")

        while true {
            try await throwIfImportShouldStop()
            let workouts = try await workoutSamples(
                startingAt: startDate,
                endingBefore: cursorEndDate,
                limit: workoutBatchLimit
            )
            guard !workouts.isEmpty else { break }

            for workout in workouts {
                try await throwIfImportShouldStop()
                let routes = try await routes(for: workout)
                for route in routes {
                    try await throwIfImportShouldStop()
                    let locations = try await locations(for: route)
                    guard locations.count >= 2 else { continue }

                    try importRouteTrack(
                        locations: locations,
                        source: .healthWorkoutRoute,
                        transportMode: transportMode(for: workout.workoutActivityType)
                    )
                    importedRouteCount += 1
                    importedSampleCount += locations.count
                }

                importedWorkoutCount += 1
                cursorEndDate = nextCursorEndDate(after: workout)
                if resumesInterruptedImport {
                    HealthWorkoutRouteImporter.persistState(
                        scope: scope,
                        startDate: startDate,
                        nextEndDate: cursorEndDate,
                        importedWorkoutCount: importedWorkoutCount,
                        importedRouteCount: importedRouteCount,
                        importedSampleCount: importedSampleCount
                    )
                }
                await progress("Checked \(importedWorkoutCount) workout\(importedWorkoutCount == 1 ? "" : "s").")
                autoreleasepool { }
            }
        }

        if resumesInterruptedImport {
            HealthWorkoutRouteImporter.clearPersistedState(scope: scope, startDate: startDate)
        }
        return HealthWorkoutRouteImportReport(
            workoutCount: importedWorkoutCount,
            routeCount: importedRouteCount,
            sampleCount: importedSampleCount,
            didResumeInterruptedImport: persistedState != nil
        )
    }

    private func importRouteTrack(
        locations: [CLLocation],
        source: LocationSampleSource,
        transportMode: TransportMode
    ) throws {
        try autoreleasepool {
            let repository = SwiftDataTimelineRepository(modelContainer: modelContainer)
            _ = try repository.importRouteTrack(
                locations: locations,
                source: source,
                transportMode: transportMode
            )
        }
    }

    private func throwIfImportShouldStop() async throws {
        if Task.isCancelled {
            throw CancellationError()
        }

        if await shouldStop() {
            throw HealthWorkoutRouteImportError.backgroundTimeExpired
        }
    }

    private func nextCursorEndDate(after workout: HKWorkout) -> Date {
        workout.startDate.addingTimeInterval(-0.001)
    }

    private func requestAuthorizationIfNeeded() async throws {
        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [], read: readTypes) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func workoutSamples(
        startingAt startDate: Date?,
        endingBefore endDate: Date?,
        limit: Int
    ) async throws -> [HKWorkout] {
        let sampleType = HKObjectType.workoutType()
        let predicate = samplePredicate(startDate: startDate, endDate: endDate)
        let sort = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: false
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: max(limit, 1),
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (samples as? [HKWorkout] ?? [])
                    .filter { Self.supportedWorkoutActivityTypes.contains($0.workoutActivityType) }
                    .sorted(by: { $0.startDate > $1.startDate })
                continuation.resume(returning: workouts)
            }

            healthStore.execute(query)
        }
    }

    private func samplePredicate(startDate: Date?, endDate: Date?) -> NSPredicate? {
        switch (startDate, endDate) {
        case let (start?, end?):
            return HKQuery.predicateForSamples(
                withStart: start,
                end: end,
                options: [.strictStartDate, .strictEndDate]
            )
        case let (start?, nil):
            return HKQuery.predicateForSamples(
                withStart: start,
                end: nil,
                options: [.strictStartDate]
            )
        case let (nil, end?):
            return HKQuery.predicateForSamples(
                withStart: nil,
                end: end,
                options: [.strictEndDate]
            )
        case (nil, nil):
            return nil
        }
    }

    private func routes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: routeType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
            }

            healthStore.execute(query)
        }
    }

    private func locations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var allLocations: [CLLocation] = []
            allLocations.reserveCapacity(2_048)
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let locations {
                    allLocations.append(contentsOf: locations)
                    if allLocations.count > self.maximumImportedRouteLocationCount {
                        allLocations = Self.downsample(
                            allLocations,
                            targetCount: self.maximumImportedRouteLocationCount
                        )
                    }
                }

                if done {
                    continuation.resume(returning: allLocations)
                }
            }

            healthStore.execute(query)
        }
    }

    private static func downsample(
        _ locations: [CLLocation],
        targetCount: Int
    ) -> [CLLocation] {
        guard locations.count > targetCount, targetCount > 1 else { return locations }
        let step = max(Double(locations.count - 1) / Double(targetCount - 1), 1)
        var reduced: [CLLocation] = []
        reduced.reserveCapacity(targetCount)

        for index in 0..<targetCount {
            let rawIndex = Int((Double(index) * step).rounded(.toNearestOrAwayFromZero))
            reduced.append(locations[min(rawIndex, locations.count - 1)])
        }

        if let last = locations.last, reduced.last?.timestamp != last.timestamp {
            reduced.append(last)
        }
        return reduced
    }

    private func transportMode(for activityType: HKWorkoutActivityType) -> TransportMode {
        switch activityType {
        case .running:
            return .running
        case .cycling, .handCycling:
            return .cycling
        case .walking, .hiking:
            return .walking
        case .swimming:
            return .swimming
        default:
            return .unknown
        }
    }

    private static let supportedWorkoutActivityTypes: Set<HKWorkoutActivityType> = [
        .running,
        .cycling,
        .handCycling,
        .walking,
        .hiking,
        .swimming
    ]
}

extension HealthWorkoutRouteImporter {
    nonisolated fileprivate static func persistedState(
        matching scope: ImportScope,
        startDate: Date?
    ) -> PersistedHealthWorkoutRouteImportState? {
        guard let data = UserDefaults.standard.data(forKey: persistedStateKey),
              let state = try? JSONDecoder().decode(PersistedHealthWorkoutRouteImportState.self, from: data),
              state.scope == scope,
              datesMatch(state.startDate, startDate) else {
            return nil
        }

        return state
    }

    nonisolated fileprivate static func persistState(
        scope: ImportScope,
        startDate: Date?,
        nextEndDate: Date?,
        importedWorkoutCount: Int,
        importedRouteCount: Int,
        importedSampleCount: Int
    ) {
        let state = PersistedHealthWorkoutRouteImportState(
            scope: scope,
            startDate: startDate,
            nextEndDate: nextEndDate,
            importedWorkoutCount: importedWorkoutCount,
            importedRouteCount: importedRouteCount,
            importedSampleCount: importedSampleCount,
            updatedAt: .now
        )

        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: persistedStateKey)
    }

    nonisolated fileprivate static func clearPersistedState(scope: ImportScope, startDate: Date?) {
        guard persistedState(matching: scope, startDate: startDate) != nil else { return }
        UserDefaults.standard.removeObject(forKey: persistedStateKey)
    }

    nonisolated fileprivate static func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) < 1
        default:
            return false
        }
    }
}

@MainActor
final class HealthWorkoutRouteAutoImportManager: ObservableObject {
    @Published private(set) var lastAutomaticImportAt: Date?
    @Published private(set) var lastAutomaticImportMessage: String?
    @Published private(set) var isHistoricalImporting = false
    @Published private(set) var historicalImportProgressText = ""
    @Published private(set) var lastHistoricalImportReport: HealthWorkoutRouteImportReport?
    @Published private(set) var lastHistoricalImportErrorMessage: String?

    private let modelContainer: ModelContainer
    private let healthStore = HKHealthStore()
    private var observerQueries: [HKObserverQuery] = []
    private var settingsObserver: NSObjectProtocol?
    private var isImporting = false
    private var pendingAutomaticImportTask: Task<Void, Never>?
    private var foregroundAutomaticImportTask: Task<Void, Never>?
    private var historicalImportTask: Task<Void, Never>?
    private var historicalImporter: HealthWorkoutRouteImporter?
    private var historicalImportID = UUID()
    private var observerStartDate: Date?
    private let automaticImportDaysBack = 3
    private let automaticImportDelay: Duration = .seconds(1)
    private let delayedRouteFollowUpDelay: Duration = .seconds(20)
    private let foregroundAutomaticImportDelay: Duration = .seconds(15)
    private let automaticImportMinimumInterval: TimeInterval = 30 * 60
    private let foregroundAutomaticImportMinimumInterval: TimeInterval = 12 * 60 * 60
    private let observerStartupGracePeriod: TimeInterval = 10

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        lastAutomaticImportAt = HealthWorkoutRouteImportSettings.lastAutomaticImportAt
        settingsObserver = NotificationCenter.default.addObserver(
            forName: HealthWorkoutRouteImportSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAfterSettingsChange()
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        pendingAutomaticImportTask?.cancel()
        foregroundAutomaticImportTask?.cancel()
        historicalImportTask?.cancel()
    }

    func refreshInterruptedHistoricalImportState() {
        guard HealthWorkoutRouteImporter.hasInterruptedHistoricalImport else { return }
        let message = "A previous Health route import was paused. Open Apple Health Routes settings to resume it."
        lastHistoricalImportErrorMessage = message
        lastAutomaticImportMessage = message
    }

    func startHistoricalImportIfNeeded() {
        guard historicalImportTask == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            lastHistoricalImportErrorMessage = "Health data is not available on this device."
            return
        }

        let importID = UUID()
        historicalImportID = importID
        isHistoricalImporting = true
        historicalImportProgressText = "Preparing import..."
        lastHistoricalImportReport = nil
        lastHistoricalImportErrorMessage = nil

        let importer = HealthWorkoutRouteImporter(
            modelContainer: modelContainer,
            progressDidChange: { [weak self] text in
                guard let self, self.historicalImportID == importID else { return }
                self.historicalImportProgressText = text
            }
        )
        historicalImporter = importer

        historicalImportTask = Task(priority: .background) { [weak self] in
            await importer.importAllWorkoutRoutes()

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard historicalImportID == importID else { return }

                historicalImportTask = nil
                historicalImporter = nil
                isHistoricalImporting = false
                historicalImportProgressText = ""
                recordAutomaticImportCheck()

                if let report = importer.lastReport {
                    lastHistoricalImportReport = report
                    lastAutomaticImportMessage = "Historical Health route import added \(report.routeCount) route(s)."
                } else if let message = importer.lastErrorMessage {
                    lastHistoricalImportErrorMessage = message
                    lastAutomaticImportMessage = message
                }
            }
        }
    }

    func cancelHistoricalImport() {
        guard isHistoricalImporting else { return }
        historicalImporter?.cancelImport()
        historicalImportTask?.cancel()
        historicalImportID = UUID()
        historicalImportTask = nil
        historicalImporter = nil
        isHistoricalImporting = false
        historicalImportProgressText = ""
        lastHistoricalImportReport = nil
        lastHistoricalImportErrorMessage = "Import paused. Progress was saved and the next import will resume from the last checked workout."
        lastAutomaticImportMessage = lastHistoricalImportErrorMessage
    }

    func startIfNeeded() async {
        guard HealthWorkoutRouteImportSettings.isEnabled else {
            stopObserving()
            return
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            lastAutomaticImportMessage = "Health data is not available on this device."
            stopObserving()
            return
        }

        startObservingWorkoutChanges()
        scheduleForegroundAutomaticImportIfNeeded()
    }

    private func refreshAfterSettingsChange() async {
        guard HealthWorkoutRouteImportSettings.isEnabled else {
            stopObserving()
            return
        }

        await startIfNeeded()
    }

    @discardableResult
    private func importConfiguredSpan(daysBack: Int) async -> Bool {
        guard !isImporting else { return false }

        isImporting = true
        defer { isImporting = false }

        let importer = HealthWorkoutRouteImporter(modelContainer: modelContainer)
        await importer.importRecentWorkoutRoutes(daysBack: daysBack)

        recordAutomaticImportCheck()

        if let report = importer.lastReport {
            lastAutomaticImportMessage = "Automatically imported \(report.routeCount) Health route(s)."
        } else {
            lastAutomaticImportMessage = importer.lastErrorMessage
        }

        return true
    }

    private func startObservingWorkoutChanges() {
        guard observerQueries.isEmpty else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }

        observerStartDate = .now
        let sampleTypes: [HKSampleType] = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]

        for sampleType in sampleTypes {
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                if let error {
                    Task { @MainActor in
                        self?.lastAutomaticImportMessage = error.localizedDescription
                    }
                    completionHandler()
                    return
                }

                Task { @MainActor in
                    self?.scheduleAutomaticImport()
                    completionHandler()
                }
            }

            observerQueries.append(query)
            healthStore.execute(query)
            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { _, _ in }
        }
    }

    private func scheduleAutomaticImport() {
        guard !isWithinObserverStartupGracePeriod else {
            return
        }

        pendingAutomaticImportTask?.cancel()
        foregroundAutomaticImportTask?.cancel()
        foregroundAutomaticImportTask = nil
        let automaticImportDelay = automaticImportDelay
        let delayedRouteFollowUpDelay = delayedRouteFollowUpDelay
        let automaticImportDaysBack = automaticImportDaysBack
        pendingAutomaticImportTask = Task { [weak self] in
            try? await Task.sleep(for: automaticImportDelay)
            guard !Task.isCancelled else { return }
            guard await self?.runAutomaticImportIfDue(daysBack: automaticImportDaysBack) == true else {
                return
            }

            try? await Task.sleep(for: delayedRouteFollowUpDelay)
            guard !Task.isCancelled else { return }
            await self?.importConfiguredSpan(daysBack: automaticImportDaysBack)
        }
    }

    private func scheduleForegroundAutomaticImportIfNeeded() {
        guard shouldRunForegroundAutomaticImport else { return }

        foregroundAutomaticImportTask?.cancel()
        let foregroundAutomaticImportDelay = foregroundAutomaticImportDelay
        let automaticImportDaysBack = automaticImportDaysBack
        foregroundAutomaticImportTask = Task { [weak self] in
            try? await Task.sleep(for: foregroundAutomaticImportDelay)
            guard !Task.isCancelled else { return }
            _ = await self?.runAutomaticImportIfDue(daysBack: automaticImportDaysBack)
            await MainActor.run {
                self?.foregroundAutomaticImportTask = nil
            }
        }
    }

    private func runAutomaticImportIfDue(daysBack: Int) async -> Bool {
        guard shouldRunAutomaticImport else {
            lastAutomaticImportMessage = "Health route import checked recently."
            return false
        }

        return await importConfiguredSpan(daysBack: daysBack)
    }

    private var shouldRunAutomaticImport: Bool {
        guard let lastAutomaticImportAt else { return true }
        return Date.now.timeIntervalSince(lastAutomaticImportAt) >= automaticImportMinimumInterval
    }

    private var shouldRunForegroundAutomaticImport: Bool {
        guard foregroundAutomaticImportTask == nil else { return false }
        guard let lastAutomaticImportAt else { return true }
        return Date.now.timeIntervalSince(lastAutomaticImportAt) >= foregroundAutomaticImportMinimumInterval
    }

    private var isWithinObserverStartupGracePeriod: Bool {
        guard let observerStartDate else { return false }
        return Date.now.timeIntervalSince(observerStartDate) < observerStartupGracePeriod
    }

    private func recordAutomaticImportCheck() {
        let now = Date.now
        lastAutomaticImportAt = now
        HealthWorkoutRouteImportSettings.lastAutomaticImportAt = now
    }

    private func stopObserving() {
        pendingAutomaticImportTask?.cancel()
        pendingAutomaticImportTask = nil
        foregroundAutomaticImportTask?.cancel()
        foregroundAutomaticImportTask = nil
        observerStartDate = nil

        for observerQuery in observerQueries {
            healthStore.stop(observerQuery)
        }
        observerQueries.removeAll()

        if HKHealthStore.isHealthDataAvailable() {
            healthStore.disableBackgroundDelivery(for: HKObjectType.workoutType()) { _, _ in }
            healthStore.disableBackgroundDelivery(for: HKSeriesType.workoutRoute()) { _, _ in }
        }
    }
}
