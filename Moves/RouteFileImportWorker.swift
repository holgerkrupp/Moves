import CoreLocation
import SwiftData

/// Owns route-file persistence on a SwiftData actor. The UI importer only supplies parser
/// DTOs and durable progress; CLLocation and model objects never cross the actor boundary.
@ModelActor
actor RouteFileImportWorker {
    struct Result: Sendable {
        var routeCount = 0
        var sampleCount = 0
        var dirtyAggregatePeriodKeys = Set<String>()
    }

    enum WorkerError: Error, Sendable {
        case paused
    }

    private static let commitChunkSize = 256
    private static let summaryRefreshRouteInterval = 16

    func importTracks(
        _ tracks: [RouteTrackDTO],
        configuration: RouteFileImportConfiguration,
        shouldPause: @Sendable @escaping () async -> Bool
    ) async throws -> Result {
        let repository = SwiftDataTimelineRepository(modelContext: modelContext)
        var result = Result()
        var previousImportedMove: MoveSegment?
        let importedTracks = tracks.map(makeImportedTrack).sorted {
            ($0.locations.first?.timestamp ?? .distantFuture) < ($1.locations.first?.timestamp ?? .distantFuture)
        }

        for track in importedTracks where track.locations.count >= 2 {
            try await checkpoint(shouldPause)
            if configuration.existingDataPolicy == .skipDate,
               try hasExistingData(for: track.locations) {
                previousImportedMove = nil
                continue
            }

            let mode = configuration.mappingMode == .dedicatedTransport
                ? configuration.dedicatedTransportMode
                : (configuration.mappingMode == .raw ? .unknown : track.transportMode)
            var chunks = [track.locations]
            if configuration.existingDataPolicy == .expandAroundExisting {
                chunks = try expandedImportChunks(for: track.locations)
            } else if configuration.existingDataPolicy == .overwriteExisting {
                try removeExistingData(overlapping: track.locations)
            }
            let importsWholeTrack = chunks.count == 1 && chunks.first?.count == track.locations.count
            var lastMoveInTrack: MoveSegment?

            for (index, chunk) in chunks.enumerated() where chunk.count >= 2 {
                try await checkpoint(shouldPause)
                let resolvedMode = mode == .unknown
                    ? ImportedTransportModeInference.infer(from: chunk) ?? .unknown
                    : mode
                let precedingVisit = importsWholeTrack && index == 0 && track.startsAfterVisitGap
                    ? previousImportedMove?.endPlace : nil
                let move = try repository.importRouteTrack(
                    locations: chunk,
                    source: .fileRouteImport,
                    transportMode: resolvedMode,
                    resolvePlaceNames: false,
                    continuingFrom: precedingVisit
                )
                if let move {
                    result.routeCount += 1
                    result.sampleCount += chunk.count
                    result.dirtyAggregatePeriodKeys.formUnion(
                        aggregatePeriodKeys(for: chunk.map(\.timestamp))
                    )
                    lastMoveInTrack = move
                    if result.routeCount == 1
                        || result.routeCount.isMultiple(of: Self.summaryRefreshRouteInterval) {
                        NotificationCenter.default.post(
                            name: .movesImportedRouteDataDidChange,
                            object: nil
                        )
                    }
                }
                if result.routeCount % Self.commitChunkSize == 0 {
                    try repository.saveIfNeeded()
                    await Task.yield()
                }
            }
            previousImportedMove = importsWholeTrack ? lastMoveInTrack : nil
        }
        try repository.saveIfNeeded()
        return result
    }

    /// Optional place naming runs after the import has reached its durable completion point.
    /// It uses the same actor/context, so background geocoding cannot race the UI context.
    func postProcessImportedPlaces() async {
        guard !Task.isCancelled else { return }
        let importedMoveIDs: Set<UUID>
        let places: [VisitPlace]
        do {
            let importedSource = LocationSampleSource.fileRouteImport.rawValue
            let samplePredicate = #Predicate<LocationSample> { sample in
                sample.sourceRawValue == importedSource
            }
            let importedSampleMoveIDs = Set(try modelContext.fetch(FetchDescriptor(predicate: samplePredicate))
                .compactMap { $0.moveSegment?.id })
            let movePredicate = #Predicate<MoveSegment> { move in
                importedSampleMoveIDs.contains(move.id)
            }
            importedMoveIDs = Set(try modelContext.fetch(FetchDescriptor(predicate: movePredicate)).map(\.id))
            let placePredicate = #Predicate<VisitPlace> { place in
                place.horizontalAccuracy <= 180
            }
            places = try modelContext.fetch(FetchDescriptor(predicate: placePredicate)).filter { place in
                let isImported = place.dayTimeline?.moves.contains { importedMoveIDs.contains($0.id) } == true
                let hasLabel = !(place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !(place.autoLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                return isImported && !hasLabel && place.horizontalAccuracy <= 180
            }
        } catch {
            return
        }

        let resolver = CLGeocoderPlaceNameResolver()
        for place in places {
            guard !Task.isCancelled else { return }
            if let name = await resolver.resolveName(for: place.coordinate) {
                place.autoLabel = name
                try? modelContext.save()
            }
        }
    }

    private func checkpoint(_ shouldPause: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        if await shouldPause() { throw WorkerError.paused }
    }

    private func makeImportedTrack(_ dto: RouteTrackDTO) -> ImportedRouteTrack {
        dto.makeImportedTrack()
    }

    private func aggregatePeriodKeys(for dates: [Date]) -> Set<String> {
        let calendar = Calendar.autoupdatingCurrent
        return Set(dates.flatMap { date in
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { return [String]() }
            return [
                String(format: "month:%04d-%02d", year, month),
                "year:\(year)"
            ]
        })
    }

    private func hasExistingData(for locations: [CLLocation]) throws -> Bool {
        guard let start = locations.map(\.timestamp).min(),
              let end = locations.map(\.timestamp).max() else { return false }
        let dayStart = Calendar.current.startOfDay(for: start)
        let dayEnd = Calendar.current.startOfDay(for: end)
        let predicate = #Predicate<DayTimeline> { day in
            day.dayStart >= dayStart && day.dayStart <= dayEnd
        }
        // The date predicate keeps this existence check proportional to the imported
        // window. SwiftData cannot currently express `hasRecordedActivity` because it
        // is derived from optional relationship storage, so only the bounded candidates
        // are inspected in memory.
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).contains(where: { $0.hasRecordedActivity })
    }

    private func expandedImportChunks(for locations: [CLLocation]) throws -> [[CLLocation]] {
        guard let start = locations.map(\.timestamp).min(),
              let end = locations.map(\.timestamp).max() else { return [] }
        let predicate = #Predicate<MoveSegment> { move in
            move.startDate <= end && move.endDate >= start
        }
        let intervals = try modelContext.fetch(FetchDescriptor(predicate: predicate)).map { ($0.startDate, $0.endDate) }
        let available = locations.filter { location in
            !intervals.contains { location.timestamp >= $0.0 && location.timestamp <= $0.1 }
        }
        guard !available.isEmpty else { return [] }
        var chunks = [[CLLocation]]()
        for location in available {
            if chunks.last?.last.map({ location.timestamp.timeIntervalSince($0.timestamp) > 10 * 60 }) == true {
                chunks.append([])
            }
            if chunks.isEmpty { chunks.append([]) }
            chunks[chunks.count - 1].append(location)
        }
        return chunks.filter { $0.count >= 2 }
    }

    private func removeExistingData(overlapping locations: [CLLocation]) throws {
        guard let start = locations.map(\.timestamp).min(), let end = locations.map(\.timestamp).max() else { return }
        let movePredicate = #Predicate<MoveSegment> { move in
            move.startDate <= end && move.endDate >= start
        }
        let samplePredicate = #Predicate<LocationSample> { sample in
            sample.timestamp >= start && sample.timestamp <= end
        }
        let moves = try modelContext.fetch(FetchDescriptor(predicate: movePredicate))
        let samples = try modelContext.fetch(FetchDescriptor(predicate: samplePredicate))
        moves.forEach(modelContext.delete)
        samples.forEach(modelContext.delete)
        try modelContext.save()
    }
}
