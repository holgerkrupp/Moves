import BackgroundTasks
import CoreLocation
import CryptoKit
import Foundation
import OSLog
import SwiftData

struct ShareMapAggregateTrack {
    let id: UUID
    let transportMode: TransportMode
    let coordinates: [CLLocationCoordinate2D]
    let usesDetailedRoute: Bool
}

@Model
final class ShareMapAggregate {
    var periodKey: String = ""
    var periodRawValue: String = ""
    var periodStart: Date = Date.now
    var sourceSignature: String = ""
    var generatedAt: Date = Date.now

    @Attribute(.externalStorage)
    var tracksData: Data? = nil

    init(
        periodKey: String,
        period: MovesSharePeriod,
        periodStart: Date,
        sourceSignature: String,
        tracksData: Data
    ) {
        self.periodKey = periodKey
        self.periodRawValue = period.rawValue
        self.periodStart = periodStart
        self.sourceSignature = sourceSignature
        self.generatedAt = .now
        self.tracksData = tracksData
    }
}

enum ShareMapAggregateStore {
    private struct StoredTrack: Codable {
        let id: UUID
        let transportModeRawValue: String
        let coordinatesData: Data
        let usesDetailedRoute: Bool?
    }

    static func supports(_ period: MovesSharePeriod) -> Bool {
        period == .month || period == .year
    }

    static func periodKey(
        for period: MovesSharePeriod,
        date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        guard supports(period) else { return nil }
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year else { return nil }
        if period == .year {
            return "year:" + String(year)
        }
        guard let month = components.month else { return nil }
        return String(format: "month:%04d-%02d", year, month)
    }

    static func sourceSignature(for timelines: [DayTimeline]) -> String {
        let source = timelines
            .sorted { $0.dayKey < $1.dayKey }
            .map { day in
                let moves = day.moves.sorted { $0.id.uuidString < $1.id.uuidString }
                let places = day.places.sorted { $0.id.uuidString < $1.id.uuidString }
                let moveSignature = moves.map { move in
                    let storedRouteBytes = (move.manualRouteCoordinatesData?.count ?? 0)
                        + (move.routeCacheCoordinatesData?.count ?? 0)
                    return [
                        move.id.uuidString,
                        move.transportModeRawValue,
                        String(move.startDate.timeIntervalSinceReferenceDate),
                        String(move.endDate.timeIntervalSinceReferenceDate),
                        String(Int(move.distanceMeters.rounded())),
                        move.routeCacheSignature ?? "",
                        String(storedRouteBytes),
                        move.usesHighAccuracyRouteTracking ? "detailed" : "synthetic"
                    ].joined(separator: ":")
                }
                .joined(separator: ",")
                let placeSignature = places.map { place in
                    [
                        place.id.uuidString,
                        String(place.arrivalDate.timeIntervalSinceReferenceDate),
                        String(place.departureDate?.timeIntervalSinceReferenceDate ?? 0),
                        String(Int((place.latitude * 100_000).rounded())),
                        String(Int((place.longitude * 100_000).rounded()))
                    ].joined(separator: ":")
                }
                .joined(separator: ",")
                return [day.dayKey, moveSignature, placeSignature].joined(separator: "|")
            }
            .joined(separator: ";")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func cachedTracks(
        for period: MovesSharePeriod,
        periodStart: Date,
        timelines: [DayTimeline],
        in context: ModelContext
    ) -> [ShareMapAggregateTrack]? {
        guard let key = periodKey(for: period, date: periodStart) else { return nil }
        var descriptor = FetchDescriptor<ShareMapAggregate>(
            predicate: #Predicate { $0.periodKey == key },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let aggregate = try? context.fetch(descriptor).first,
              aggregate.sourceSignature == sourceSignature(for: timelines),
              let data = aggregate.tracksData else {
            return nil
        }
        return decodeTracks(data)
    }

    static func encodeTracks(_ tracks: [ShareMapAggregateTrack]) throws -> Data {
        let stored = tracks.map {
            StoredTrack(
                id: $0.id,
                transportModeRawValue: $0.transportMode.rawValue,
                coordinatesData: RouteCoordinateStorage.encode($0.coordinates) ?? Data(),
                usesDetailedRoute: $0.usesDetailedRoute
            )
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(stored)
    }

    private static func decodeTracks(_ data: Data) -> [ShareMapAggregateTrack]? {
        guard let stored = try? PropertyListDecoder().decode([StoredTrack].self, from: data) else {
            return nil
        }
        return stored.compactMap { track in
            let coordinates = RouteCoordinateStorage.decode(track.coordinatesData)
            guard coordinates.count > 1 else { return nil }
            return ShareMapAggregateTrack(
                id: track.id,
                transportMode: TransportMode(rawValue: track.transportModeRawValue) ?? .unknown,
                coordinates: coordinates,
                usesDetailedRoute: track.usesDetailedRoute ?? false
            )
        }
    }
}

enum ShareMapAggregateBuilder {
    private static let log = Logger(subsystem: "de.holgerkrupp.Moves", category: "ShareMapAggregate")

    static func refreshAll(in modelContainer: ModelContainer) async {
        let work = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let context = ModelContext(modelContainer)
                let timelines = try context.fetch(
                    FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.dayStart, order: .forward)])
                )
                try refresh(timelines: timelines, in: context)
            } catch is CancellationError {
                return
            } catch {
                log.error("Could not refresh map aggregates: \(error.localizedDescription, privacy: .public)")
            }
        }
        await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }

    static func refresh(
        period: MovesSharePeriod,
        periodStart: Date,
        in modelContainer: ModelContainer,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async {
        guard ShareMapAggregateStore.supports(period) else { return }
        progress(0)
        let work = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                progress(0.05)
                let context = ModelContext(modelContainer)
                let timelines = try context.fetch(
                    FetchDescriptor<DayTimeline>(sortBy: [SortDescriptor(\.dayStart, order: .forward)])
                )
                progress(0.12)
                let selected = selectedTimelines(
                    from: timelines,
                    period: period,
                    periodStart: periodStart
                )
                try rebuildIfNeeded(
                    timelines: selected,
                    period: period,
                    periodStart: period.start(for: periodStart),
                    in: context,
                    progress: progress
                )
                progress(1)
            } catch is CancellationError {
                return
            } catch {
                log.error("Could not refresh requested map aggregate: \(error.localizedDescription, privacy: .public)")
            }
        }
        await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }

    private static func refresh(timelines: [DayTimeline], in context: ModelContext) throws {
        let activeTimelines = timelines.filter(\.hasRecordedActivity)
        for period in [MovesSharePeriod.month, .year] {
            try Task.checkCancellation()
            let grouped = Dictionary(grouping: activeTimelines) {
                period.start(for: $0.dayStart)
            }
            for periodStart in grouped.keys.sorted() {
                try Task.checkCancellation()
                try rebuildIfNeeded(
                    timelines: grouped[periodStart] ?? [],
                    period: period,
                    periodStart: periodStart,
                    in: context
                )
            }
        }
    }

    private static func rebuildIfNeeded(
        timelines: [DayTimeline],
        period: MovesSharePeriod,
        periodStart: Date,
        in context: ModelContext,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        guard !timelines.isEmpty,
              let key = ShareMapAggregateStore.periodKey(for: period, date: periodStart) else { return }
        progress?(0.16)
        let signature = ShareMapAggregateStore.sourceSignature(for: timelines)
        let descriptor = FetchDescriptor<ShareMapAggregate>(
            predicate: #Predicate { $0.periodKey == key },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        let existing = try context.fetch(descriptor)
        if existing.first?.sourceSignature == signature, existing.first?.tracksData != nil {
            progress?(1)
            return
        }

        let maximumCoordinateCount = period == .year ? 80 : 120
        let moves = timelines
            .flatMap(\.moves)
            .sorted { $0.startDate < $1.startDate }
        var tracks: [ShareMapAggregateTrack] = []
        tracks.reserveCapacity(moves.count)
        for (index, move) in moves.enumerated() {
            try Task.checkCancellation()
            let fallback = MoveRouteGeometry.rawCoordinates(for: move)
            let routeSignature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
            let coordinates = move.manualRouteCoordinates
                ?? move.cachedRouteCoordinates(for: routeSignature)
                ?? fallback
            if coordinates.count > 1 {
                tracks.append(ShareMapAggregateTrack(
                    id: move.id,
                    transportMode: move.transportMode,
                    coordinates: downsampled(coordinates, maximumCount: maximumCoordinateCount),
                    usesDetailedRoute: move.usesHighAccuracyRouteTracking
                ))
            }
            if index % 8 == 0 || index == moves.count - 1 {
                let completed = Double(index + 1) / Double(max(moves.count, 1))
                progress?(0.18 + completed * 0.74)
            }
        }
        try Task.checkCancellation()
        progress?(0.94)
        let data = try ShareMapAggregateStore.encodeTracks(tracks)

        let aggregate: ShareMapAggregate
        if let current = existing.first {
            aggregate = current
            aggregate.periodRawValue = period.rawValue
            aggregate.periodStart = periodStart
            aggregate.sourceSignature = signature
            aggregate.generatedAt = .now
            aggregate.tracksData = data
        } else {
            aggregate = ShareMapAggregate(
                periodKey: key,
                period: period,
                periodStart: periodStart,
                sourceSignature: signature,
                tracksData: data
            )
            context.insert(aggregate)
        }
        for duplicate in existing.dropFirst() {
            context.delete(duplicate)
        }
        try context.save()
        progress?(1)
        log.info("Stored \(tracks.count) tracks for \(key, privacy: .public)")
    }

    private static func selectedTimelines(
        from timelines: [DayTimeline],
        period: MovesSharePeriod,
        periodStart: Date
    ) -> [DayTimeline] {
        timelines.filter {
            $0.hasRecordedActivity && period.contains($0.dayStart, periodStart: periodStart)
        }
    }

    private static func downsampled(
        _ coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount, maximumCount > 1 else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            coordinates[min(Int((Double(index) * step).rounded()), coordinates.count - 1)]
        }
    }
}

enum ShareMapAggregateBackgroundTask {
    static let taskIdentifier = "de.holgerkrupp.Moves.shareMapAggregates"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handle(task as! BGProcessingTask)
        }
    }

    static func scheduleNextRun(now: Date = .now) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Calendar.current.date(byAdding: .hour, value: 6, to: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        scheduleNextRun()
        let work = Task {
            do {
                let container = try await MainActor.run { try MovesApp.makeModelContainer() }
                await ShareMapAggregateBuilder.refreshAll(in: container)
                task.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
