import CoreLocation
import SwiftData

/// Conservative, local-only transport inference for imported routes that did not carry a mode.
/// A nil result means the available geometry is too ambiguous and should remain unknown.
enum ImportedTransportModeInference {
    static func infer(
        from locations: [CLLocation],
        distanceMeters storedDistance: CLLocationDistance? = nil,
        duration storedDuration: TimeInterval? = nil
    ) -> TransportMode? {
        let ordered = locations
            .filter {
                CLLocationCoordinate2DIsValid($0.coordinate)
                    && $0.timestamp.timeIntervalSinceReferenceDate.isFinite
            }
            .sorted { $0.timestamp < $1.timestamp }

        let routeDuration = max(
            storedDuration ?? 0,
            ordered.last.flatMap { last in
                ordered.first.map { last.timestamp.timeIntervalSince($0.timestamp) }
            } ?? 0
        )
        guard routeDuration >= 60 else { return nil }

        var derivedSpeeds: [CLLocationSpeed] = []
        var measuredDistance: CLLocationDistance = 0
        if ordered.count >= 2 {
            for (previous, next) in zip(ordered, ordered.dropFirst()) {
                let interval = next.timestamp.timeIntervalSince(previous.timestamp)
                guard interval > 0 else { continue }
                let distance = previous.distance(from: next)
                let speed = distance / interval
                // Discard teleport-like GPS errors without throwing away sparse flight legs.
                guard speed.isFinite, speed <= 400 else { continue }
                measuredDistance += distance
                derivedSpeeds.append(speed)
            }
        }

        // Some exporters fill every speed field with zero. Prefer coordinate-derived speed
        // unless there are several genuinely moving observations.
        let recordedSpeeds = ordered.map(\.speed).filter { $0 > 0.1 && $0 <= 400 }
        let speeds = recordedSpeeds.count >= 3 ? recordedSpeeds : derivedSpeeds
        let distance = max(measuredDistance, storedDistance ?? 0)
        guard distance >= 100 else { return nil }

        let endpointDistance: CLLocationDistance = {
            guard let first = ordered.first, let last = ordered.last else { return 0 }
            return first.distance(from: last)
        }()
        let directDistance = max(endpointDistance, ordered.count < 2 ? distance : 0)
        let directSpeed = directDistance / routeDuration
        let averageSpeed = distance / routeDuration
        let maximumAltitude = ordered
            .filter { $0.verticalAccuracy >= 0 || $0.altitude != 0 }
            .map(\.altitude)
            .filter(\.isFinite)
            .max() ?? 0
        let upperSpeed = percentile(0.8, of: speeds) ?? averageSpeed

        // Cruise altitude is the strongest signal. For files without altitude, require a
        // sustained speed that normal rail and road travel cannot plausibly reach.
        let altitudeIndicatesFlight = maximumAltitude >= 2_000
            && directDistance >= 30_000
            && directSpeed >= 35
        let speedIndicatesFlight = directDistance >= 80_000
            && directSpeed >= 95
            && upperSpeed >= 90
        if routeDuration >= 10 * 60 && (altitudeIndicatesFlight || speedIndicatesFlight) {
            return .plane
        }

        // Two distant points can establish flight-like speed, but are not enough to
        // distinguish walking, running, cycling, and road travel with useful confidence.
        guard speeds.count >= 3 else { return nil }
        let medianSpeed = percentile(0.5, of: speeds) ?? averageSpeed
        let highSpeed = percentile(0.9, of: speeds) ?? upperSpeed

        if averageSpeed <= 2.0, medianSpeed <= 2.1, highSpeed <= 3.0 {
            return .walking
        }
        if averageSpeed >= 1.8, averageSpeed <= 5.5,
           medianSpeed >= 2.0, highSpeed <= 8.0 {
            return .running
        }
        if averageSpeed >= 2.5, averageSpeed <= 12,
           medianSpeed >= 3.0, highSpeed <= 20 {
            return .cycling
        }
        if averageSpeed >= 5.5, medianSpeed >= 6.5, highSpeed <= 80 {
            return .automotive
        }
        return nil
    }

    private static func percentile(_ fraction: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

@ModelActor
actor ImportedTransportModeInferenceWorker {
    /// Revisits existing imported moves. It never changes an explicit transport choice and
    /// deliberately leaves weak evidence as Unknown.
    func refineUnknownImportedMoves() async -> Int {
        let moves: [MoveSegment]
        do {
            let descriptor = FetchDescriptor<MoveSegment>(
                predicate: #Predicate { $0.transportModeRawValue == "unknown" },
                sortBy: [SortDescriptor(\MoveSegment.startDate)]
            )
            moves = try modelContext.fetch(descriptor)
        } catch {
            return 0
        }

        var changedCount = 0
        for move in moves {
            guard !Task.isCancelled else { break }
            let importedSamples = move.samples
                .filter { $0.source == .fileRouteImport }
                .sorted { $0.timestamp < $1.timestamp }
            guard !importedSamples.isEmpty else { continue }

            let inferred = ImportedTransportModeInference.infer(
                from: importedSamples.map(\.asLocation),
                distanceMeters: move.distanceMeters,
                duration: move.endDate.timeIntervalSince(move.startDate)
            )
            guard let inferred else { continue }
            move.transportMode = inferred
            move.clearCachedRouteCoordinates()
            changedCount += 1

            if changedCount.isMultiple(of: 100) {
                try? modelContext.save()
                await Task.yield()
            }
        }

        guard changedCount > 0 else { return 0 }
        try? modelContext.save()
        NotificationCenter.default.post(name: .movesImportedRouteDataDidChange, object: nil)
        NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
        return changedCount
    }
}

enum ImportedTransportModeRefinement {
    static func run(in modelContainer: ModelContainer) async {
        let worker = await Task.detached(priority: .utility) {
            ImportedTransportModeInferenceWorker(modelContainer: modelContainer)
        }.value
        _ = await worker.refineUnknownImportedMoves()
    }
}
