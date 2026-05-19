import Foundation
import CoreLocation
import HealthKit
import SwiftData

struct HealthWorkoutRouteImportReport {
    let workoutCount: Int
    let routeCount: Int
    let sampleCount: Int
}

enum HealthWorkoutRouteImportSettings {
    static let isEnabledKey = "Moves.healthWorkoutRouteImport.isEnabled"
    static let didChangeNotification = Notification.Name("Moves.healthWorkoutRouteImport.didChange")

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }
}

@MainActor
final class HealthWorkoutRouteImporter: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: Double?
    @Published private(set) var importProgressText = ""
    @Published private(set) var lastReport: HealthWorkoutRouteImportReport?
    @Published private(set) var lastErrorMessage: String?

    private let healthStore = HKHealthStore()
    private let modelContext: ModelContext
    private let workoutBatchLimit = 40

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func importRecentWorkoutRoutes(daysBack: Int = 30) async {
        let startDate = Calendar.current.date(
            byAdding: .day,
            value: -daysBack,
            to: .now
        ) ?? .now.addingTimeInterval(-TimeInterval(daysBack * 24 * 60 * 60))

        await importWorkoutRoutes(startingAt: startDate)
    }

    func importAllWorkoutRoutes() async {
        await importWorkoutRoutes(startingAt: nil)
    }

    private func importWorkoutRoutes(startingAt startDate: Date?) async {
        guard !isImporting else { return }
        guard isAvailable else {
            lastErrorMessage = "Health data is not available on this device."
            return
        }

        isImporting = true
        importProgress = nil
        importProgressText = "Preparing import..."
        defer {
            isImporting = false
            importProgress = nil
            importProgressText = ""
        }

        do {
            try await requestAuthorizationIfNeeded()

            let repository = SwiftDataTimelineRepository(modelContext: modelContext)
            var importedRouteCount = 0
            var importedSampleCount = 0
            var importedWorkoutCount = 0
            var cursorEndDate: Date?
            importProgress = nil
            importProgressText = "Preparing import..."

            while true {
                let workouts = try await workoutSamples(
                    startingAt: startDate,
                    endingBefore: cursorEndDate,
                    limit: workoutBatchLimit
                )
                guard !workouts.isEmpty else { break }

                for workout in workouts {
                    let routes = try await routes(for: workout)
                    for route in routes {
                        let locations = try await locations(for: route)
                        guard locations.count >= 2 else { continue }

                        _ = try repository.importRouteTrack(
                            locations: locations,
                            source: .healthWorkoutRoute,
                            transportMode: transportMode(for: workout.workoutActivityType)
                        )
                        importedRouteCount += 1
                        importedSampleCount += locations.count
                    }

                    importedWorkoutCount += 1
                    importProgressText = "Checked \(importedWorkoutCount) workout\(importedWorkoutCount == 1 ? "" : "s")."
                    autoreleasepool { }
                }

                cursorEndDate = workouts.last?.startDate.addingTimeInterval(-1)
            }

            try repository.saveIfNeeded()
            lastReport = HealthWorkoutRouteImportReport(
                workoutCount: importedWorkoutCount,
                routeCount: importedRouteCount,
                sampleCount: importedSampleCount
            )
            lastErrorMessage = nil
            if importedWorkoutCount == 0 {
                importProgressText = "No supported workouts found."
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
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
                    if allLocations.count > 12_000 {
                        allLocations = Self.downsample(allLocations)
                    }
                }

                if done {
                    continuation.resume(returning: allLocations)
                }
            }

            healthStore.execute(query)
        }
    }

    nonisolated private static func downsample(_ locations: [CLLocation]) -> [CLLocation] {
        guard locations.count > 2 else { return locations }
        var reduced: [CLLocation] = []
        reduced.reserveCapacity((locations.count / 2) + 1)
        for index in stride(from: 0, to: locations.count, by: 2) {
            reduced.append(locations[index])
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

    nonisolated private static let supportedWorkoutActivityTypes: Set<HKWorkoutActivityType> = [
        .running,
        .cycling,
        .handCycling,
        .walking,
        .hiking,
        .swimming
    ]
}

@MainActor
final class HealthWorkoutRouteAutoImportManager: ObservableObject {
    @Published private(set) var lastAutomaticImportAt: Date?
    @Published private(set) var lastAutomaticImportMessage: String?

    private let modelContainer: ModelContainer
    private let healthStore = HKHealthStore()
    private var observerQuery: HKObserverQuery?
    private var settingsObserver: NSObjectProtocol?
    private var isImporting = false

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
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

        await importConfiguredSpan()
        startObservingWorkoutChanges()
    }

    private func refreshAfterSettingsChange() async {
        guard HealthWorkoutRouteImportSettings.isEnabled else {
            stopObserving()
            return
        }

        await startIfNeeded()
    }

    private func importConfiguredSpan() async {
        guard !isImporting else { return }

        isImporting = true
        defer { isImporting = false }

        let context = ModelContext(modelContainer)
        let importer = HealthWorkoutRouteImporter(modelContext: context)
        await importer.importRecentWorkoutRoutes()

        lastAutomaticImportAt = .now

        if let report = importer.lastReport {
            lastAutomaticImportMessage = "Automatically imported \(report.routeCount) Health route(s)."
        } else {
            lastAutomaticImportMessage = importer.lastErrorMessage
        }
    }

    private func startObservingWorkoutChanges() {
        guard observerQuery == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let sampleType = HKObjectType.workoutType()
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
            if let error {
                Task { @MainActor in
                    self?.lastAutomaticImportMessage = error.localizedDescription
                }
                completionHandler()
                return
            }

            Task { @MainActor in
                await self?.importConfiguredSpan()
                completionHandler()
            }
        }

        observerQuery = query
        healthStore.execute(query)
        healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { _, _ in }
    }

    private func stopObserving() {
        if let observerQuery {
            healthStore.stop(observerQuery)
            self.observerQuery = nil
        }

        if HKHealthStore.isHealthDataAvailable() {
            healthStore.disableBackgroundDelivery(for: HKObjectType.workoutType()) { _, _ in }
        }
    }
}
