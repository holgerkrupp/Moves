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

    static func periodKeys(
        for dates: [Date],
        calendar: Calendar = .autoupdatingCurrent
    ) -> Set<String> {
        Set(dates.flatMap { date in
            [periodKey(for: .month, date: date, calendar: calendar),
             periodKey(for: .year, date: date, calendar: calendar)].compactMap { $0 }
        })
    }

    static func dateInterval(for key: String) -> DateInterval? {
        let components = key.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              let value = Int(components[1]) else {
            if key.hasPrefix("month:"),
               let date = DateFormatter.shareAggregateMonth.date(from: String(components.last ?? "")) {
                return MovesSharePeriod.month.dateInterval(containing: date)
            }
            return nil
        }
        if key.hasPrefix("year:") {
            let calendar = Calendar.autoupdatingCurrent
            guard let date = calendar.date(from: DateComponents(year: value)) else { return nil }
            return MovesSharePeriod.year.dateInterval(containing: date, calendar: calendar)
        }
        return nil
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
        guard !ShareMapAggregateDirtyPeriods.contains(key) else { return nil }
        var descriptor = FetchDescriptor<ShareMapAggregate>(
            predicate: #Predicate { $0.periodKey == key },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let aggregate = try? context.fetch(descriptor).first,
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

private extension DateFormatter {
    static let shareAggregateMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}

/// Persisted outside the CloudKit timeline schema so an interrupted import can resume
/// aggregate reconciliation without adding cache metadata to synced user data.
enum ShareMapAggregateDirtyPeriods {
    private static let key = "Moves.shareMapAggregateDirtyPeriods"
    private static let lock = NSLock()

    static func mark(_ periodKeys: Set<String>) {
        guard !periodKeys.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let existing = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        UserDefaults.standard.set(Array(existing.union(periodKeys)).sorted(), forKey: key)
    }

    static func contains(_ periodKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(periodKey)
    }

    static func take() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let periods = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        UserDefaults.standard.removeObject(forKey: key)
        return periods
    }

    static func restore(_ periodKeys: Set<String>) {
        mark(periodKeys)
    }

    static func clear(_ periodKeys: Set<String>) {
        guard !periodKeys.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = Set(UserDefaults.standard.stringArray(forKey: key) ?? []).subtracting(periodKeys)
        UserDefaults.standard.set(Array(remaining).sorted(), forKey: key)
    }
}

enum ShareMapAggregateBuilder {
    private static let log = Logger(subsystem: "de.holgerkrupp.Moves", category: "ShareMapAggregate")

    static func refreshAll(in modelContainer: ModelContainer) async {
        await refreshDirty(in: modelContainer)
    }

    static func refreshDirty(in modelContainer: ModelContainer) async {
        let periodKeys = ShareMapAggregateDirtyPeriods.take()
        guard !periodKeys.isEmpty else { return }
        await refresh(periodKeys: periodKeys, in: modelContainer)
    }

    static func refresh(periodKeys: Set<String>, in modelContainer: ModelContainer) async {
        guard !periodKeys.isEmpty else { return }
        let work = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let context = ModelContext(modelContainer)
                try refresh(periodKeys: periodKeys, in: context)
                ShareMapAggregateDirtyPeriods.clear(periodKeys)
            } catch is CancellationError {
                ShareMapAggregateDirtyPeriods.restore(periodKeys)
            } catch {
                log.error("Could not refresh map aggregates: \(error.localizedDescription, privacy: .public)")
                ShareMapAggregateDirtyPeriods.restore(periodKeys)
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
                guard let interval = period.dateInterval(containing: periodStart) else { return }
                let predicate = #Predicate<DayTimeline> { day in
                    day.dayStart >= interval.start && day.dayStart < interval.end
                }
                let timelines = try context.fetch(FetchDescriptor(predicate: predicate))
                progress(0.12)
                try rebuildIfNeeded(
                    timelines: timelines.filter(\.hasRecordedActivity),
                    period: period,
                    periodStart: period.start(for: periodStart),
                    in: context,
                    progress: progress
                )
                ShareMapAggregateDirtyPeriods.clear(Set([
                    ShareMapAggregateStore.periodKey(for: period, date: periodStart)
                ].compactMap { $0 }))
                progress(1)
            } catch is CancellationError {
                if let key = ShareMapAggregateStore.periodKey(for: period, date: periodStart) {
                    ShareMapAggregateDirtyPeriods.restore([key])
                }
            } catch {
                log.error("Could not refresh requested map aggregate: \(error.localizedDescription, privacy: .public)")
            }
        }
        await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }

    private static func refresh(periodKeys: Set<String>, in context: ModelContext) throws {
        for key in periodKeys.sorted() {
            try Task.checkCancellation()
            guard let interval = ShareMapAggregateStore.dateInterval(for: key) else { continue }
            let period: MovesSharePeriod = key.hasPrefix("month:") ? .month : .year
            let predicate = #Predicate<DayTimeline> { day in
                day.dayStart >= interval.start && day.dayStart < interval.end
            }
            let timelines = try context.fetch(FetchDescriptor(predicate: predicate))
            try rebuildIfNeeded(
                timelines: timelines.filter(\.hasRecordedActivity),
                period: period,
                periodStart: interval.start,
                in: context
            )
        }
    }

    private static func rebuildIfNeeded(
        timelines: [DayTimeline],
        period: MovesSharePeriod,
        periodStart: Date,
        in context: ModelContext,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        guard let key = ShareMapAggregateStore.periodKey(for: period, date: periodStart) else { return }
        progress?(0.16)
        if timelines.isEmpty {
            let descriptor = FetchDescriptor<ShareMapAggregate>(predicate: #Predicate { $0.periodKey == key })
            for aggregate in try context.fetch(descriptor) {
                context.delete(aggregate)
            }
            try context.save()
            progress?(1)
            return
        }
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
        request.earliestBeginDate = nextRunDate(now: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func nextRunDate(
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let tonight = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: startOfToday)
        if let tonight, tonight > now {
            return tonight
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        return calendar.date(bySettingHour: 2, minute: 0, second: 0, of: tomorrow) ?? tomorrow
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
