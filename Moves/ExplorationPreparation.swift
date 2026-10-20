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
    var processedHistoricalDayKeys: Set<String> = []
    /// Cumulative time spent doing preparation work, excluding time waiting for
    /// iOS to grant another execution window.
    var successfulRuntime: TimeInterval = 0
    var isProcessing = false
    /// Lease used to recover a checkpoint left in the processing state after
    /// termination or a background-task expiration.
    var processingLeaseUntil: Date?
    var updatedAt = Date.distantPast

    private enum CodingKeys: String, CodingKey {
        case readiness
        case nextDayKey
        case processedThroughDayKey
        case preparedShardCount
        case startedAt
        case totalDayCount
        case processedDayCount
        case processedHistoricalDayKeys
        case successfulRuntime
        case isProcessing
        case processingLeaseUntil
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
        processedHistoricalDayKeys = try container.decodeIfPresent(Set<String>.self, forKey: .processedHistoricalDayKeys) ?? []
        successfulRuntime = try container.decodeIfPresent(TimeInterval.self, forKey: .successfulRuntime) ?? 0
        isProcessing = try container.decodeIfPresent(Bool.self, forKey: .isProcessing) ?? false
        processingLeaseUntil = try container.decodeIfPresent(Date.self, forKey: .processingLeaseUntil)
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
        guard checkpoint.successfulRuntime > 0, processedDayCount > 0 else { return nil }
        return Double(processedDayCount) / (checkpoint.successfulRuntime / 3_600)
    }

    var estimatedCompletionDate: Date? {
        guard let remainingDayCount,
              remainingDayCount > 0,
              checkpoint.successfulRuntime > 1,
              processedDayCount > 0 else {
            return nil
        }
        let secondsPerDay = checkpoint.successfulRuntime / Double(processedDayCount)
        return now.addingTimeInterval(secondsPerDay * Double(remainingDayCount))
    }

    init(checkpoint: ExplorationPreparationCheckpoint, now: Date = .now) {
        self.checkpoint = checkpoint
        self.now = now
    }
}

struct ExplorationPreparationBudget: Sendable {
    var maximumDays = 1
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
        return try JSONDecoder().decode(ExplorationPreparationCheckpoint.self, from: ExplorationFileStorage.readData(from: url))
    }

    func save(_ checkpoint: ExplorationPreparationCheckpoint) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try ExplorationFileStorage.writeAtomically(data, to: url)
    }

    /// Deletes all Phase A source shards, merged blocks, and the preparation
    /// checkpoint. Authoritative SwiftData/CloudKit history is not touched.
    func removeAllPreparationData() throws {
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let paths = [
            root.appendingPathComponent("v1/sources", isDirectory: true),
            root.appendingPathComponent("v1/source-index.json"),
            root.appendingPathComponent("v1/source-index.pending"),
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

    func nextDay(after dayKey: String?) throws -> ExplorationDayInput? {
        var descriptor = FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\DayTimeline.dayKey)])
        descriptor.fetchLimit = 1
        if let dayKey {
            descriptor.predicate = #Predicate<DayTimeline> { day in
                day.dayKey > dayKey
            }
        }
        guard let day = try modelContext.fetch(descriptor).first else { return nil }

        return try makeInput(from: day)
    }

    func day(with dayKey: String) throws -> ExplorationDayInput? {
        let descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { $0.dayKey == dayKey }
        )
        guard let day = try modelContext.fetch(descriptor).first else { return nil }
        return try makeInput(from: day)
    }

    private func makeInput(from day: DayTimeline) throws -> ExplorationDayInput {

        var routes: [ExplorationRouteInput] = []
        // A route cap silently discarded source history. Days are bounded by
        // the worker window and raster resource limits instead.
        routes.reserveCapacity(day.moves.count)
        for move in day.moves {
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

    private static let coordinator = ExplorationPreparationSingleFlight()
    private static let diagnostics = ExplorationPreparationDiagnostics()

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
#if DEBUG
        userDefaults.bool(forKey: isEnabledKey)
#else
        // Phase A is intentionally silent in release builds. The preparation
        // worker is bounded and disposable, so production devices can slowly
        // build the data needed by the later user-facing Exploration rollout.
        true
#endif
    }

    /// Runs at most one bounded historical source unit by default. Nothing calls
    /// this from SwiftUI or launch in Phase A; a later rollout can enable it after
    /// the performance gate has been measured.
    static func runSlice(
        in modelContainer: ModelContainer,
        rootURL: URL = ExplorationStorageLocations.rootURL,
        budget: ExplorationPreparationBudget = ExplorationPreparationBudget()
    ) async throws -> ExplorationPreparationResult {
        await coordinator.acquire()
        await diagnostics.start(stage: "slice-start")
        do {
            let result = try await runSliceExclusively(in: modelContainer, rootURL: rootURL, budget: budget)
            await coordinator.release()
            return result
        } catch {
            let failureContext = await diagnostics.failureContext()
            await diagnostics.fail(error.localizedDescription)
            if let itemID = failureContext.itemID {
                try? await ExplorationWorkQueue.shared.retry(itemID, error: error.localizedDescription)
            }
            if failureContext.itemID == nil,
               let dayKey = failureContext.dayKey,
               failureContext.lane == ExplorationWorkLane.historical.title {
                try? await ExplorationWorkQueue.shared.enqueue(dayKeys: [dayKey], lane: .historical)
                var checkpoint = (try? await ExplorationPreparationCheckpointStore(rootURL: rootURL).load())
                    ?? ExplorationPreparationCheckpoint()
                if checkpoint.nextDayKey == nil || checkpoint.nextDayKey! < dayKey {
                    checkpoint.nextDayKey = dayKey
                }
                checkpoint.readiness = .partiallyReady
                checkpoint.isProcessing = false
                checkpoint.processingLeaseUntil = nil
                checkpoint.updatedAt = .now
                try? await ExplorationPreparationCheckpointStore(rootURL: rootURL).save(checkpoint)
            } else {
                var checkpoint = (try? await ExplorationPreparationCheckpointStore(rootURL: rootURL).load())
                checkpoint?.isProcessing = false
                checkpoint?.processingLeaseUntil = nil
                checkpoint?.updatedAt = .now
                if let checkpoint {
                    try? await ExplorationPreparationCheckpointStore(rootURL: rootURL).save(checkpoint)
                }
            }
            await coordinator.release()
            throw error
        }
    }

    private static func runSliceExclusively(
        in modelContainer: ModelContainer,
        rootURL: URL,
        budget: ExplorationPreparationBudget
    ) async throws -> ExplorationPreparationResult {
        let startedWorkAt = Date.now
        guard budget.maximumDays > 0 else {
            throw PreparationError.budgetExceeded
        }
        try await ExplorationPreparationResourceGate.check()
        let checkpointStore = ExplorationPreparationCheckpointStore(rootURL: rootURL)
        var checkpoint = try await checkpointStore.load()
        let sourceWorker = ExplorationPreparationSourceWorker(modelContainer: modelContainer)

        let now = Date.now
        if checkpoint.startedAt == nil {
            checkpoint.startedAt = now
        }
        let checkpointLeaseExpired = checkpoint.processingLeaseUntil.map { $0 <= now }
            ?? (checkpoint.updatedAt.addingTimeInterval(15 * 60) <= now)
        if checkpoint.isProcessing, checkpointLeaseExpired {
            // Checkpoints written by older builds have no lease field. An old
            // processing marker is therefore treated as abandoned as well.
            checkpoint.isProcessing = false
            checkpoint.processingLeaseUntil = nil
        }
        // Count the bounded DayTimeline work units, not LocationSample rows. This is
        // persisted for the debug projection and is never performed by SwiftUI.
        await diagnostics.start(stage: "source-fetch")
        let currentDayCount = try await sourceWorker.dayCount()
        await diagnostics.finish(stage: "source-fetch")
        checkpoint.totalDayCount = max(checkpoint.totalDayCount ?? 0, currentDayCount)
        checkpoint.processedDayCount = max(checkpoint.processedDayCount, checkpoint.preparedShardCount)
        UserDefaults.standard.set(
            max(0, currentDayCount - checkpoint.processedDayCount),
            forKey: "Moves.exploration.historicalBacklog"
        )
        checkpoint.readiness = .preparing
        checkpoint.isProcessing = true
        checkpoint.processingLeaseUntil = now.addingTimeInterval(15 * 60)
        checkpoint.updatedAt = now
        try await checkpointStore.save(checkpoint)

        let workQueue = ExplorationWorkQueue.shared
        await diagnostics.start(stage: "route-input")
        let claimedWork = try await workQueue.claim(maximum: 1)
        var claimedWorkID = claimedWork.first?.id
        if let claimed = claimedWork.first {
            await diagnostics.setWork(itemID: claimed.id, dayKey: claimed.dayKey, lane: claimed.lane.title)
        }

        let input: ExplorationDayInput
        let isQueuedWork: Bool
        if let queued = claimedWork.first,
           let queuedInput = try await sourceWorker.day(with: queued.dayKey) {
            input = queuedInput
            isQueuedWork = true
        } else {
            if let queued = claimedWork.first {
                try await workQueue.complete(queued.id)
                claimedWorkID = nil
                await diagnostics.clearWork()
            }
            guard let historicalInput = try await sourceWorker.nextDay(after: checkpoint.nextDayKey) else {
                let outstanding = try await workQueue.snapshot()
                let hasOutstandingWork = outstanding.queuedCount + outstanding.delayedCount + outstanding.processingCount > 0
                checkpoint.readiness = hasOutstandingWork
                    ? .partiallyReady
                    : (checkpoint.processedDayCount == 0 ? .notStarted : .ready)
                checkpoint.isProcessing = false
                checkpoint.processingLeaseUntil = nil
                try await checkpointStore.save(checkpoint)
                return ExplorationPreparationResult(daysProcessed: 0, routesProcessed: 0, blocksWritten: 0, checkpoint: checkpoint)
            }
            input = historicalInput
            isQueuedWork = false
        }

        await diagnostics.finish(
            stage: "route-input",
            dayKey: input.dayKey,
            routeCount: input.routes.count,
            lane: isQueuedWork ? claimedWork.first?.lane.title : ExplorationWorkLane.historical.title
        )

        if input.routes.isEmpty && input.visits.isEmpty && !isQueuedWork {
            // Quiet days still advance the durable cursor. Otherwise the first
            // empty DayTimeline would stop historical preparation permanently.
            checkpoint.nextDayKey = input.dayKey
            checkpoint.processedThroughDayKey = input.dayKey
            if checkpoint.processedHistoricalDayKeys.insert(input.dayKey).inserted {
                checkpoint.processedDayCount += 1
            }
            checkpoint.successfulRuntime += max(0, Date.now.timeIntervalSince(startedWorkAt))
            checkpoint.readiness = .partiallyReady
            checkpoint.isProcessing = false
            checkpoint.processingLeaseUntil = nil
            checkpoint.updatedAt = .now
            try await checkpointStore.save(checkpoint)
            return ExplorationPreparationResult(daysProcessed: 1, routesProcessed: 0, blocksWritten: 0, checkpoint: checkpoint)
        }
        try Task.checkCancellation()
        try await ExplorationPreparationResourceGate.check()
        let sources = ExplorationShardFileStore(rootURL: rootURL)
        let sourceID = "day:\(input.dayKey)"
        let previousRevision = try await sources.read(sourceID: sourceID)?.revision ?? 0
        await diagnostics.start(stage: "raster", dayKey: input.dayKey, routeCount: input.routes.count)
        let shard = try await Task.detached(priority: .utility) {
            try ExplorationPerformance.measure("shard generation") {
                try makeShard(from: input, revision: previousRevision + 1, budget: budget)
            }
        }.value
        await diagnostics.finish(stage: "raster", dayKey: input.dayKey, routeCount: input.routes.count)
        let cache = ExplorationMergedCache(rootURL: rootURL, shardStore: sources)
        await diagnostics.start(stage: "merged-cache", dayKey: input.dayKey, routeCount: input.routes.count)
        try await cache.replaceShard(shard, updateCountryPresence: false)
        await diagnostics.finish(stage: "merged-cache", dayKey: input.dayKey, routeCount: input.routes.count)
        // Keep the compact country-day index moving with the same bounded
        // source unit. This is deliberately one-shard work and does not scan
        // the rest of the history from the preparation slice.
        await diagnostics.start(stage: "country-day-index", dayKey: input.dayKey, routeCount: input.routes.count)
        try await ExplorationCountryPresenceIndexStore(rootURL: rootURL).update(with: shard)
        await diagnostics.finish(stage: "country-day-index", dayKey: input.dayKey, routeCount: input.routes.count)
        if !isQueuedWork {
            checkpoint.nextDayKey = input.dayKey
            checkpoint.processedThroughDayKey = input.dayKey
            if checkpoint.processedHistoricalDayKeys.insert(input.dayKey).inserted {
                checkpoint.preparedShardCount += 1
                checkpoint.processedDayCount += 1
            }
        } else if claimedWork.first?.lane == .historical {
            if checkpoint.processedHistoricalDayKeys.insert(input.dayKey).inserted {
                checkpoint.preparedShardCount += 1
                checkpoint.processedDayCount += 1
            }
            checkpoint.processedThroughDayKey = max(checkpoint.processedThroughDayKey ?? input.dayKey, input.dayKey)
        }
        checkpoint.readiness = .partiallyReady
        checkpoint.isProcessing = false
        checkpoint.processingLeaseUntil = nil
        checkpoint.updatedAt = .now
        if !isQueuedWork {
            checkpoint.successfulRuntime += max(0, Date.now.timeIntervalSince(startedWorkAt))
        }
        await diagnostics.start(stage: "checkpoint-commit", dayKey: input.dayKey, routeCount: input.routes.count)
        try await checkpointStore.save(checkpoint)
        await diagnostics.finish(stage: "checkpoint-commit", dayKey: input.dayKey, routeCount: input.routes.count)
        if let claimedWorkID {
            try await workQueue.complete(claimedWorkID)
        }
        return ExplorationPreparationResult(
            daysProcessed: 1,
            routesProcessed: input.routes.count,
            blocksWritten: shard.blocks.count,
            checkpoint: checkpoint
        )
    }

    /// Runs several independently checkpointed day slices during one
    /// opportunistic overnight window. Each iteration remains bounded and
    /// cancellable; the window stops at the first resource/cancellation signal,
    /// when the backlog is exhausted, or when either cap is reached.
    static func runBackgroundWindow(
        in modelContainer: ModelContainer,
        rootURL: URL = ExplorationStorageLocations.rootURL,
        sliceBudget: ExplorationPreparationBudget = ExplorationPreparationBudget(),
        maximumDays: Int = 64,
        maximumDuration: TimeInterval = 120
    ) async throws -> [ExplorationPreparationResult] {
        guard maximumDays > 0, maximumDuration > 0 else { return [] }
        let checkpoint = try await ExplorationPreparationCheckpointStore(rootURL: rootURL).load()
        let adaptiveDayLimit: Int
        if checkpoint.successfulRuntime > 0, checkpoint.processedDayCount > 0 {
            let secondsPerDay = checkpoint.successfulRuntime / Double(checkpoint.processedDayCount)
            adaptiveDayLimit = min(maximumDays, max(1, Int(maximumDuration / max(secondsPerDay, 1))))
        } else {
            adaptiveDayLimit = min(maximumDays, 16)
        }
        let deadline = Date().addingTimeInterval(maximumDuration)
        var results: [ExplorationPreparationResult] = []
        results.reserveCapacity(adaptiveDayLimit)

        while results.count < adaptiveDayLimit, Date() < deadline {
            try Task.checkCancellation()
            try await ExplorationPreparationResourceGate.check()

            var boundedBudget = sliceBudget
            boundedBudget.maximumDays = 1
            let result = try await runSlice(
                in: modelContainer,
                rootURL: rootURL,
                budget: boundedBudget
            )
            results.append(result)

            // A zero-day result means there is no next DayTimeline work unit.
            if result.daysProcessed == 0 { break }
            await Task.yield()
        }

        return results
    }

    private static func makeShard(
        from input: ExplorationDayInput,
        revision: UInt64,
        budget: ExplorationPreparationBudget
    ) throws -> ExplorationShard {
        var bitmaps = [FogBlockID: [ExplorationLayer: FogBitmapBlock]]()

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
            // Do not turn a valid but large day into a permanent historical
            // cursor stop. The caller still checks cancellation between route
            // segments and commits the completed day as one atomic shard.
        }

        for route in input.routes {
            try Task.checkCancellation()
            guard let first = route.coordinates.first,
                  let firstAddress = try? FogRasterV1.address(for: first.clCoordinate) else { continue }
            var previous = firstAddress.cell
            for coordinate in route.coordinates.dropFirst() {
                try Task.checkCancellation()
                guard let currentAddress = try? FogRasterV1.address(for: coordinate.clCoordinate) else { continue }
                var traversed = 0
                try FogRasterV1.forEachCellAlongLine(from: previous, to: currentAddress.cell) { cell in
                    traversed += 1
                    if traversed.isMultiple(of: 4_096) { try Task.checkCancellation() }
                    try set(cell, layer: route.layer)
                }
                previous = currentAddress.cell
            }
            try set(previous, layer: route.layer)
        }

        for visit in input.visits {
            try Task.checkCancellation()
            guard let address = try? FogRasterV1.address(for: visit.clCoordinate) else { continue }
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
                }
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

actor ExplorationPreparationDiagnostics {
    private struct Event: Codable {
        var stage: String
        var dayKey: String?
        var routeCount: Int?
        var lane: String?
        var itemID: String?
        var startedAt: Date
        var endedAt: Date?
        var durationMilliseconds: Double?
        var error: String?
    }

    private var current: Event?
    private let key: String

    init(key: String = "Moves.exploration.preparation.lastStage") {
        self.key = key
    }

    func start(stage: String, dayKey: String? = nil, routeCount: Int? = nil, lane: String? = nil) {
        let previous = stage == "slice-start" ? nil : current
        current = Event(
            stage: stage,
            dayKey: dayKey ?? previous?.dayKey,
            routeCount: routeCount ?? previous?.routeCount,
            lane: lane ?? previous?.lane,
            itemID: previous?.itemID,
            startedAt: .now,
            endedAt: nil,
            durationMilliseconds: nil,
            error: nil
        )
        persist()
    }

    func finish(stage: String, dayKey: String? = nil, routeCount: Int? = nil, lane: String? = nil) {
        if current?.stage != stage {
            start(stage: stage, dayKey: dayKey, routeCount: routeCount, lane: lane)
        }
        guard var event = current else { return }
        event.dayKey = dayKey ?? event.dayKey
        event.routeCount = routeCount ?? event.routeCount
        event.lane = lane ?? event.lane
        event.endedAt = .now
        let duration = max(0, event.endedAt!.timeIntervalSince(event.startedAt) * 1_000)
        event.durationMilliseconds = duration
        current = event
        let durationKey = "Moves.exploration.preparation.stageDurations.\(stage)"
        var durations = UserDefaults.standard.array(forKey: durationKey) as? [Double] ?? []
        durations.append(duration)
        if durations.count > 128 { durations.removeFirst(durations.count - 128) }
        UserDefaults.standard.set(durations, forKey: durationKey)
        persist()
    }

    func fail(_ message: String) {
        guard var event = current else { return }
        event.error = message
        current = event
        persist()
    }

    func setWork(itemID: String, dayKey: String, lane: String) {
        guard var event = current else { return }
        event.itemID = itemID
        event.dayKey = dayKey
        event.lane = lane
        current = event
        persist()
    }

    func clearWork() {
        guard var event = current else { return }
        event.itemID = nil
        event.lane = nil
        current = event
        persist()
    }

    func failureContext() -> (dayKey: String?, lane: String?, itemID: String?) {
        (current?.dayKey, current?.lane, current?.itemID)
    }

    private func persist() {
        guard let current, let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum ExplorationSchedulingPolicy {
    /// A missing earliest date means the request is already eligible. Keep it;
    /// only replace a dated request when newly urgent work is earlier.
    static func shouldReplace(
        existingEarliest: Date?,
        existingRequiresExternalPower: Bool = false,
        desiredEarliest: Date,
        desiredRequiresExternalPower: Bool = false
    ) -> Bool {
        if let existingEarliest, existingEarliest < desiredEarliest { return false }
        if existingRequiresExternalPower && !desiredRequiresExternalPower { return true }
        if !existingRequiresExternalPower && desiredRequiresExternalPower { return false }
        guard let existingEarliest else { return false }
        return desiredEarliest < existingEarliest
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

private actor ExplorationPreparationSingleFlight {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isOccupied {
            isOccupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

#if !os(macOS)
enum ExplorationPreparationBackgroundTask {
    static let taskIdentifier = "de.holgerkrupp.Moves.explorationPreparation"
    private static let defaults = UserDefaults.standard
    private static let pendingKey = "Moves.exploration.bg.pendingDate"
    private static let resultKey = "Moves.exploration.bg.lastResult"
    private static let eventKey = "Moves.exploration.bg.lastEvent"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                defaults.set("Unexpected background task type", forKey: resultKey)
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    static func schedule(now: Date = .now, urgent: Bool = false) {
        guard ExplorationPreparation.isEnabled() else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = backlogIsSubstantial && !urgent
        request.earliestBeginDate = urgent || backlogIsSubstantial ? now : nextRunDate(now: now)
        BGTaskScheduler.shared.getPendingTaskRequests { pending in
            let existing = pending.first { $0.identifier == taskIdentifier }
            let existingProcessingRequest = existing as? BGProcessingTaskRequest
            if let existing,
               !ExplorationSchedulingPolicy.shouldReplace(
                   existingEarliest: existing.earliestBeginDate,
                   existingRequiresExternalPower: existingProcessingRequest?.requiresExternalPower ?? false,
                   desiredEarliest: request.earliestBeginDate!,
                   desiredRequiresExternalPower: request.requiresExternalPower
               ) {
                defaults.set(existing.earliestBeginDate, forKey: pendingKey)
                defaults.set("Existing request retained", forKey: resultKey)
                return
            }
            if existing != nil {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            }
            do {
                try BGTaskScheduler.shared.submit(request)
                defaults.set(request.earliestBeginDate, forKey: pendingKey)
                defaults.set("Submitted", forKey: resultKey)
                defaults.set(now, forKey: eventKey)
            } catch {
                defaults.set("Submission failed: \(error.localizedDescription)", forKey: resultKey)
                defaults.set(now, forKey: eventKey)
            }
        }
    }

    private static var backlogIsSubstantial: Bool {
        defaults.integer(forKey: "Moves.exploration.historicalBacklog") > 30
    }

    static func nextRunDate(
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        if let tonight = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: startOfToday), tonight > now {
            return tonight
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        return calendar.date(bySettingHour: 3, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private static func handle(_ task: BGProcessingTask) {
        defaults.set(Date.now, forKey: "Moves.exploration.bg.lastStart")
        defaults.set(true, forKey: "Moves.exploration.bg.isProcessing")
        defaults.removeObject(forKey: pendingKey)
        defaults.set("Granted", forKey: resultKey)
        var didComplete = false
        let completionLock = NSLock()
        func finish(_ success: Bool, result: String) {
            completionLock.lock()
            guard !didComplete else { completionLock.unlock(); return }
            didComplete = true
            completionLock.unlock()
            defaults.set(false, forKey: "Moves.exploration.bg.isProcessing")
            defaults.set(result, forKey: resultKey)
            defaults.set(Date.now, forKey: eventKey)
            task.setTaskCompleted(success: success)
            schedule()
        }
        let work = Task {
            do {
                let container = try await MainActor.run { try MovesApp.makeModelContainer() }
                _ = try await ExplorationPreparation.runBackgroundWindow(in: container)
                finish(!Task.isCancelled, result: Task.isCancelled ? "Cancelled" : "Completed")
            } catch {
                finish(false, result: "Failed: \(error.localizedDescription)")
            }
        }
        task.expirationHandler = {
            defaults.set(Date.now, forKey: "Moves.exploration.bg.lastExpiration")
            defaults.set("Expired", forKey: resultKey)
            work.cancel()
            finish(false, result: "Expired")
        }
    }
}
#else
enum ExplorationPreparationBackgroundTask {
    static func register() {}
    static func schedule() {}
}
#endif
