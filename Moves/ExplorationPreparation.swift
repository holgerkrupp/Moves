import BackgroundTasks
import CoreLocation
import Foundation
import OSLog
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

enum ExplorationReadiness: String, Codable, Sendable {
    case notStarted
    case preparing
    case partiallyReady
    case ready
    case needsRebuild
}

struct ExplorationPreparationCheckpoint: Codable, Equatable, Sendable {
    var readiness: ExplorationReadiness = .notStarted
    var nextDayKey: String?
    var processedThroughDayKey: String?
    var preparedShardCount = 0
    /// Wall-clock time at which the first preparation slice began.
    var startedAt: Date?
    /// Snapshot of the number of DayTimeline work units when preparation began.
    var totalDayCount: Int?
    var processedDayCount = 0
    var isProcessing = false
    var updatedAt = Date.distantPast

    private enum CodingKeys: String, CodingKey {
        case readiness
        case nextDayKey
        case processedThroughDayKey
        case preparedShardCount
        case startedAt
        case totalDayCount
        case processedDayCount
        case isProcessing
        case updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readiness = try container.decodeIfPresent(ExplorationReadiness.self, forKey: .readiness) ?? .notStarted
        nextDayKey = try container.decodeIfPresent(String.self, forKey: .nextDayKey)
        processedThroughDayKey = try container.decodeIfPresent(String.self, forKey: .processedThroughDayKey)
        preparedShardCount = try container.decodeIfPresent(Int.self, forKey: .preparedShardCount) ?? 0
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        totalDayCount = try container.decodeIfPresent(Int.self, forKey: .totalDayCount)
        processedDayCount = try container.decodeIfPresent(Int.self, forKey: .processedDayCount) ?? preparedShardCount
        isProcessing = try container.decodeIfPresent(Bool.self, forKey: .isProcessing) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

struct ExplorationPreparationStatistics: Sendable, Equatable {
    let checkpoint: ExplorationPreparationCheckpoint
    let now: Date

    var processedDayCount: Int {
        max(0, checkpoint.processedDayCount)
    }

    var remainingDayCount: Int? {
        guard let totalDayCount = checkpoint.totalDayCount else { return nil }
        return max(0, totalDayCount - processedDayCount)
    }

    var progressFraction: Double? {
        guard let totalDayCount = checkpoint.totalDayCount, totalDayCount > 0 else { return nil }
        return min(max(Double(processedDayCount) / Double(totalDayCount), 0), 1)
    }

    var elapsed: TimeInterval? {
        guard let startedAt = checkpoint.startedAt else { return nil }
        return max(0, now.timeIntervalSince(startedAt))
    }

    var averageDaysPerHour: Double? {
        guard let elapsed, elapsed > 0, processedDayCount > 0 else { return nil }
        return Double(processedDayCount) / (elapsed / 3_600)
    }

    var estimatedCompletionDate: Date? {
        guard let remainingDayCount,
              remainingDayCount > 0,
              let elapsed,
              elapsed > 1,
              processedDayCount > 0 else {
            return nil
        }
        let secondsPerDay = elapsed / Double(processedDayCount)
        return now.addingTimeInterval(secondsPerDay * Double(remainingDayCount))
    }

    init(checkpoint: ExplorationPreparationCheckpoint, now: Date = .now) {
        self.checkpoint = checkpoint
        self.now = now
    }
}

struct ExplorationPreparationBudget: Sendable {
    var maximumDays = 1
    var maximumRoutes = 64
    var maximumBlocks = 100_000
    var maximumVisitCells = 20_000
}

struct ExplorationPreparationResult: Sendable {
    let daysProcessed: Int
    let routesProcessed: Int
    let blocksWritten: Int
    let checkpoint: ExplorationPreparationCheckpoint
}

private struct ExplorationCoordinate: Sendable {
    let latitude: Double
    let longitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct ExplorationRouteInput: Sendable {
    let layer: ExplorationLayer
    let coordinates: [ExplorationCoordinate]
}

private struct ExplorationDayInput: Sendable {
    let dayKey: String
    let dayStart: Date
    let routes: [ExplorationRouteInput]
    let visits: [ExplorationCoordinate]
}

enum ExplorationStorageLocations {
    static var rootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Moves/Exploration", isDirectory: true)
    }
}

actor ExplorationPreparationCheckpointStore {
    private let url: URL

    init(rootURL: URL = ExplorationStorageLocations.rootURL) {
        self.url = rootURL.appendingPathComponent("v1/preparation.json")
    }

    func load() throws -> ExplorationPreparationCheckpoint {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ExplorationPreparationCheckpoint()
        }
        return try JSONDecoder().decode(ExplorationPreparationCheckpoint.self, from: Data(contentsOf: url))
    }

    func save(_ checkpoint: ExplorationPreparationCheckpoint) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: url, options: ExplorationFileStorage.atomicWriteOptions)
    }

    /// Deletes all Phase A source shards, merged blocks, and the preparation
    /// checkpoint. Authoritative SwiftData/CloudKit history is not touched.
    func removeAllPreparationData() throws {
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let paths = [
            root.appendingPathComponent("v1/sources", isDirectory: true),
            root.appendingPathComponent("v1/blocks", isDirectory: true),
            root.appendingPathComponent("v1/derived", isDirectory: true),
            root.appendingPathComponent("v1/render", isDirectory: true),
            root.appendingPathComponent("v1/work-queue.json"),
            url
        ]
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

@ModelActor
private actor ExplorationPreparationSourceWorker {
    func dayCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<DayTimeline>())
    }

    func nextDay(after dayKey: String?, maximumRoutes: Int) throws -> ExplorationDayInput? {
        var descriptor = FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\DayTimeline.dayKey)])
        descriptor.fetchLimit = 1
        if let dayKey {
            descriptor.predicate = #Predicate<DayTimeline> { day in
                day.dayKey > dayKey
            }
        }
        guard let day = try modelContext.fetch(descriptor).first else { return nil }

        return try makeInput(from: day, maximumRoutes: maximumRoutes)
    }

    func day(with dayKey: String, maximumRoutes: Int) throws -> ExplorationDayInput? {
        let descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { $0.dayKey == dayKey }
        )
        guard let day = try modelContext.fetch(descriptor).first else { return nil }
        return try makeInput(from: day, maximumRoutes: maximumRoutes)
    }

    private func makeInput(from day: DayTimeline, maximumRoutes: Int) throws -> ExplorationDayInput {

        var routes: [ExplorationRouteInput] = []
        routes.reserveCapacity(min(day.moves.count, maximumRoutes))
        for move in day.moves.prefix(maximumRoutes) {
            try Task.checkCancellation()
            let coordinates = MoveRouteGeometry.rawCoordinates(for: move).map {
                ExplorationCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            }
            guard !coordinates.isEmpty else { continue }
            let layer: ExplorationLayer = move.transportMode == .plane ? .flight : .ground
            routes.append(ExplorationRouteInput(layer: layer, coordinates: coordinates))
        }

        let visits = day.places.map {
            ExplorationCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        return ExplorationDayInput(dayKey: day.dayKey, dayStart: day.dayStart, routes: routes, visits: visits)
    }
}

enum ExplorationPreparation {
    static let log = Logger(subsystem: "de.holgerkrupp.Moves", category: "ExplorationPreparation")
    static let isEnabledKey = "Moves.exploration.phaseA.enabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: isEnabledKey)
    }

    /// Runs at most one bounded historical source unit by default. Nothing calls
    /// this from SwiftUI or launch in Phase A; a later rollout can enable it after
    /// the performance gate has been measured.
    static func runSlice(
        in modelContainer: ModelContainer,
        rootURL: URL = ExplorationStorageLocations.rootURL,
        budget: ExplorationPreparationBudget = ExplorationPreparationBudget()
    ) async throws -> ExplorationPreparationResult {
        guard budget.maximumDays > 0 else {
            throw PreparationError.budgetExceeded
        }
        try await ExplorationPreparationResourceGate.check()
        let checkpointStore = ExplorationPreparationCheckpointStore(rootURL: rootURL)
        var checkpoint = try await checkpointStore.load()
        let sourceWorker = ExplorationPreparationSourceWorker(modelContainer: modelContainer)

        if checkpoint.startedAt == nil {
            checkpoint.startedAt = .now
        }
        // Count the bounded DayTimeline work units, not LocationSample rows. This is
        // persisted for the debug projection and is never performed by SwiftUI.
        let currentDayCount = try await sourceWorker.dayCount()
        checkpoint.totalDayCount = max(checkpoint.totalDayCount ?? 0, currentDayCount)
        checkpoint.processedDayCount = max(checkpoint.processedDayCount, checkpoint.preparedShardCount)
        checkpoint.readiness = .preparing
        checkpoint.isProcessing = true
        checkpoint.updatedAt = .now
        try await checkpointStore.save(checkpoint)

        let workQueue = ExplorationWorkQueue.shared
        let claimedWork = try await workQueue.claim(maximum: 1)
        var claimedWorkID = claimedWork.first?.id
        var claimedWorkCompleted = false

        defer {
            Task {
                if let claimedWorkID, !claimedWorkCompleted {
                    try? await workQueue.retry(claimedWorkID, error: "Preparation slice ended before completion")
                }
                var finalCheckpoint = (try? await checkpointStore.load()) ?? checkpoint
                finalCheckpoint.isProcessing = false
                finalCheckpoint.updatedAt = .now
                try? await checkpointStore.save(finalCheckpoint)
            }
        }

        let input: ExplorationDayInput
        let isQueuedWork: Bool
        if let queued = claimedWork.first,
           let queuedInput = try await sourceWorker.day(with: queued.dayKey, maximumRoutes: budget.maximumRoutes) {
            input = queuedInput
            isQueuedWork = true
        } else {
            if let queued = claimedWork.first {
                try await workQueue.complete(queued.id)
                claimedWorkCompleted = true
                claimedWorkID = nil
            }
            guard let historicalInput = try await sourceWorker.nextDay(after: checkpoint.nextDayKey, maximumRoutes: budget.maximumRoutes) else {
                checkpoint.readiness = checkpoint.preparedShardCount == 0 ? .notStarted : .ready
                checkpoint.isProcessing = false
                try await checkpointStore.save(checkpoint)
                return ExplorationPreparationResult(daysProcessed: 0, routesProcessed: 0, blocksWritten: 0, checkpoint: checkpoint)
            }
            input = historicalInput
            isQueuedWork = false
        }

        if input.routes.isEmpty && input.visits.isEmpty && !isQueuedWork {
            checkpoint.readiness = checkpoint.preparedShardCount == 0 ? .notStarted : .ready
            checkpoint.isProcessing = false
            try await checkpointStore.save(checkpoint)
            return ExplorationPreparationResult(daysProcessed: 0, routesProcessed: 0, blocksWritten: 0, checkpoint: checkpoint)
        }

        try Task.checkCancellation()
        try await ExplorationPreparationResourceGate.check()
        let sources = ExplorationShardFileStore(rootURL: rootURL)
        let sourceID = "day:\(input.dayKey)"
        let previousRevision = try await sources.read(sourceID: sourceID)?.revision ?? 0
        let shard = try ExplorationPerformance.measure("shard generation") {
            try makeShard(from: input, revision: previousRevision + 1, budget: budget)
        }
        let cache = ExplorationMergedCache(rootURL: rootURL, shardStore: sources)
        try await cache.replaceShard(shard)
        // Keep the compact country-day index moving with the same bounded
        // source unit. This is deliberately one-shard work and does not scan
        // the rest of the history from the preparation slice.
        try await ExplorationCountryPresenceIndexStore(rootURL: rootURL).update(with: shard)
        if let claimedWorkID {
            try await workQueue.complete(claimedWorkID)
            claimedWorkCompleted = true
        }

        if !isQueuedWork {
            checkpoint.nextDayKey = input.dayKey
            checkpoint.processedThroughDayKey = input.dayKey
            checkpoint.preparedShardCount += 1
            checkpoint.processedDayCount += 1
        }
        checkpoint.readiness = .partiallyReady
        checkpoint.isProcessing = false
        checkpoint.updatedAt = .now
        try await checkpointStore.save(checkpoint)
        return ExplorationPreparationResult(
            daysProcessed: 1,
            routesProcessed: input.routes.count,
            blocksWritten: shard.blocks.count,
            checkpoint: checkpoint
        )
    }

    private static func makeShard(
        from input: ExplorationDayInput,
        revision: UInt64,
        budget: ExplorationPreparationBudget
    ) throws -> ExplorationShard {
        var bitmaps = [FogBlockID: [ExplorationLayer: FogBitmapBlock]]()
        var visitCellCount = 0

        func set(_ cell: FogCell, layer: ExplorationLayer) throws {
            let address = try FogRasterV1.address(for: cell)
            var bitmap: FogBitmapBlock
            if let existing = bitmaps[address.block]?[layer] {
                bitmap = existing
            } else {
                bitmap = try FogBitmapBlock()
            }
            bitmap.set(x: Int(address.localCellX), y: Int(address.localCellY))
            bitmaps[address.block, default: [:]][layer] = bitmap
            guard bitmaps.count <= budget.maximumBlocks else { throw PreparationError.budgetExceeded }
        }

        for route in input.routes {
            try Task.checkCancellation()
            guard let first = route.coordinates.first,
                  let firstAddress = try? FogRasterV1.address(for: first.clCoordinate) else { continue }
            var previous = firstAddress.cell
            for coordinate in route.coordinates.dropFirst() {
                guard let currentAddress = try? FogRasterV1.address(for: coordinate.clCoordinate) else { continue }
                for cell in FogRasterV1.cellsAlongLine(from: previous, to: currentAddress.cell) {
                    try set(cell, layer: route.layer)
                }
                previous = currentAddress.cell
            }
            try set(previous, layer: route.layer)
        }

        for visit in input.visits {
            guard visitCellCount < budget.maximumVisitCells,
                  let address = try? FogRasterV1.address(for: visit.clCoordinate) else { continue }
            // A visit contributes a small, deterministic disk in the same raster.
            // The radius is intentionally conservative until the Phase B product
            // semantics settle; it never creates a second geographic grid.
            let radius = 50.0
            let latitudeScale = max(cos(visit.latitude * .pi / 180), 0.05)
            let cells = max(1, Int(ceil(radius / (9.5546 * latitudeScale))))
            for y in -cells...cells {
                for x in -cells...cells where Double(x * x + y * y).squareRoot() * 9.5546 * latitudeScale <= radius {
                    let globalX = Int(address.cell.coordinate.x) + x
                    let globalY = Int(address.cell.coordinate.y) + y
                    guard globalX >= 0, globalY >= 0,
                          globalX < Int(FogRasterV1.globalCellDimension),
                          globalY < Int(FogRasterV1.globalCellDimension) else { continue }
                    try set(FogCell(coordinate: FogRasterCoordinate(x: UInt32(globalX), y: UInt32(globalY))), layer: .visits)
                    visitCellCount += 1
                    if visitCellCount >= budget.maximumVisitCells { break }
                }
                if visitCellCount >= budget.maximumVisitCells { break }
            }
        }

        let blocks = bitmaps.map { id, layerMap in
            ExplorationShardBlock(id: id, layers: layerMap.map { ExplorationLayerBitmap(layer: $0.key, bitmap: $0.value) })
        }
        return ExplorationShard(sourceID: "day:\(input.dayKey)", revision: revision, logicalStart: input.dayStart, logicalEnd: input.dayStart.addingTimeInterval(86_400), blocks: blocks)
    }

    private enum PreparationError: Error {
        case budgetExceeded
    }
}

private enum ExplorationPreparationResourceGate {
    static func check() async throws {
        try Task.checkCancellation()
        #if canImport(UIKit)
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            throw ResourceGateError.deferred
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            throw ResourceGateError.deferred
        default:
            break
        }
        #endif
        // Import is authoritative and explicitly wins over derived work. The
        // importer can set this process-wide flag around a long foreground
        // import without coupling the two actors or starting another query.
        guard !UserDefaults.standard.bool(forKey: "Moves.routeImport.isActive") else {
            throw ResourceGateError.deferred
        }
        await Task.yield()
    }

    private enum ResourceGateError: Error {
        case deferred
    }
}

#if !os(macOS)
enum ExplorationPreparationBackgroundTask {
    static let taskIdentifier = "de.holgerkrupp.Moves.explorationPreparation"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handle(task as! BGProcessingTask)
        }
    }

    static func schedule() {
        guard ExplorationPreparation.isEnabled() else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule()
        let work = Task {
            do {
                let container = try await MainActor.run { try MovesApp.makeModelContainer() }
                _ = try await ExplorationPreparation.runSlice(in: container)
                task.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
#else
enum ExplorationPreparationBackgroundTask {
    static func register() {}
    static func schedule() {}
}
#endif
