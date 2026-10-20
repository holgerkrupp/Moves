import CoreLocation
import Foundation
import SwiftData

enum TimelineDayPresentationLimits {
    static let maxLoadedMoves = 240
    static let maxLoadedPlaces = 240
    static let maxLoadedSamples = 4_000
    static let maxRouteSamplesPerMove = 500
}

struct TimelinePlaceSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let deviceIdentifier: String
    let arrivalDate: Date
    let departureDate: Date?
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let userLabel: String?
    let regularPlaceID: UUID?
    let regularPlaceName: String?
    let autoLabel: String?
    let comment: String?
    let dayKey: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayTitle: String {
        if let userLabel, !userLabel.isEmpty { return userLabel }
        if let regularPlaceName, !regularPlaceName.isEmpty { return regularPlaceName }
        if let autoLabel, !autoLabel.isEmpty { return autoLabel }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    init(_ place: VisitPlace) {
        id = place.id
        deviceIdentifier = place.deviceIdentifier
        arrivalDate = place.arrivalDate
        departureDate = place.departureDate
        latitude = place.latitude
        longitude = place.longitude
        horizontalAccuracy = place.horizontalAccuracy
        userLabel = place.userLabel
        regularPlaceID = place.regularPlaceID
        regularPlaceName = place.regularPlaceName
        autoLabel = place.autoLabel
        comment = place.comment
        dayKey = place.dayTimeline?.dayKey
    }
}

struct TimelineSampleSnapshot: Identifiable, Sendable, Hashable {
    var id: String { dedupeKey + "|" + String(timestamp.timeIntervalSince1970) }
    let dedupeKey: String
    let deviceIdentifier: String
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let speed: Double
    let sourceRawValue: String
    let moveID: UUID?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var source: LocationSampleSource {
        LocationSampleSource(rawValue: sourceRawValue) ?? .significantChange
    }

    init(_ sample: LocationSample) {
        dedupeKey = sample.dedupeKey
        deviceIdentifier = sample.deviceIdentifier
        timestamp = sample.timestamp
        latitude = sample.latitude
        longitude = sample.longitude
        altitude = sample.altitude
        horizontalAccuracy = sample.horizontalAccuracy
        speed = sample.speed
        sourceRawValue = sample.sourceRawValue
        moveID = sample.moveSegment?.id
    }
}

struct TimelineMoveSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let deviceIdentifier: String
    let startDate: Date
    let endDate: Date
    let timelineStartDate: Date
    let transportModeRawValue: String
    let distanceMeters: Double
    let stepCount: Int?
    let comment: String?
    let isExcludedFromConnectionStatistics: Bool
    let usesImportedRoute: Bool
    let usesHealthWorkoutRoute: Bool
    let usesRouteTracking: Bool
    let startPlace: TimelinePlaceSnapshot?
    let endPlace: TimelinePlaceSnapshot?
    let manualRouteCoordinates: [RouteCoordinateStoragePoint]?
    let cachedRouteCoordinates: [RouteCoordinateStoragePoint]?
    let rawRouteCoordinates: [RouteCoordinateStoragePoint]
    let routeCacheSignature: String
    let dayKey: String?

    var transportMode: TransportMode {
        TransportMode(rawValue: transportModeRawValue) ?? .unknown
    }

    var displayedRouteCoordinates: [RouteCoordinateStoragePoint] {
        manualRouteCoordinates ?? cachedRouteCoordinates ?? rawRouteCoordinates
    }

    var timelineDuration: TimeInterval {
        max(endDate.timeIntervalSince(timelineStartDate), 0)
    }

    init(
        _ move: MoveSegment,
        startPlace: TimelinePlaceSnapshot?,
        endPlace: TimelinePlaceSnapshot?,
        samples: [LocationSample],
        usesImportedRoute: Bool,
        usesHealthWorkoutRoute: Bool,
        usesRouteTracking: Bool
    ) {
        id = move.id
        deviceIdentifier = move.deviceIdentifier
        startDate = move.startDate
        endDate = move.endDate
        let departureStart = startPlace?.departureDate ?? move.startDate
        timelineStartDate = min(max(departureStart, move.startDate), move.endDate)
        transportModeRawValue = move.transportModeRawValue
        distanceMeters = move.distanceMeters
        stepCount = move.stepCount
        comment = move.comment
        isExcludedFromConnectionStatistics = move.isExcludedFromConnectionStatistics
        self.usesImportedRoute = usesImportedRoute || move.importedRouteData != nil
        self.usesHealthWorkoutRoute = usesHealthWorkoutRoute
        self.usesRouteTracking = usesRouteTracking
        self.startPlace = startPlace
        self.endPlace = endPlace
        // Match MoveSegment.manualRouteCoordinates semantics: absent or invalid
        // manual route data must remain nil so map presentation can fall back to
        // cached or recorded geometry.
        manualRouteCoordinates = move.manualRouteCoordinates?.map(RouteCoordinateStoragePoint.init)
        let fallback = MoveRouteGeometry.rawCoordinates(
            for: move,
            samples: samples,
            usesHealthWorkoutRoute: usesHealthWorkoutRoute
        )
        let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
        routeCacheSignature = signature
        // Preserve the former presentation path's device-local cache fallback.
        // The method checks the CloudKit-backed cache first, then the rebuildable
        // on-device cache, all while the model remains inside this ModelActor.
        let cached = move.cachedRouteCoordinates(for: signature) ?? []
        cachedRouteCoordinates = cached.isEmpty ? nil : cached.map(RouteCoordinateStoragePoint.init)
        rawRouteCoordinates = fallback.map(RouteCoordinateStoragePoint.init)
        dayKey = move.dayTimeline?.dayKey
    }
}

struct TimelineDaySnapshot: Sendable {
    let places: [TimelinePlaceSnapshot]
    let moves: [TimelineMoveSnapshot]
    let samples: [TimelineSampleSnapshot]
    let sourcesByMoveID: [UUID: UInt8]
    let importedMoveIDs: Set<UUID>
    let carriedOverPlace: TimelinePlaceSnapshot?
    let totalMoveCount: Int
    let totalSampleCount: Int
    let hasImportedRouteData: Bool
}

@ModelActor
actor TimelineDayPresentationWorker {
    func snapshot(dayStart: Date, loadAll: Bool = false) throws -> TimelineDaySnapshot {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let movePredicate = #Predicate<MoveSegment> { $0.startDate < dayEnd && $0.endDate >= dayStart }
        let placePredicate = #Predicate<VisitPlace> { $0.arrivalDate >= dayStart && $0.arrivalDate < dayEnd }
        let samplePredicate = #Predicate<LocationSample> { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
        let importedSource = LocationSampleSource.fileRouteImport.rawValue
        let importedPredicate = #Predicate<LocationSample> {
            $0.timestamp >= dayStart && $0.timestamp < dayEnd && $0.sourceRawValue == importedSource
        }

        var moveDescriptor = FetchDescriptor<MoveSegment>(
            predicate: movePredicate,
            sortBy: [SortDescriptor(\.endDate, order: .reverse)]
        )
        var placeDescriptor = FetchDescriptor<VisitPlace>(
            predicate: placePredicate,
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
        )
        var sampleDescriptor = FetchDescriptor<LocationSample>(
            predicate: samplePredicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if !loadAll {
            moveDescriptor.fetchLimit = TimelineDayPresentationLimits.maxLoadedMoves + 1
            placeDescriptor.fetchLimit = TimelineDayPresentationLimits.maxLoadedPlaces + 1
            sampleDescriptor.fetchLimit = TimelineDayPresentationLimits.maxLoadedSamples + 1
        }

        let fetchedMoves = try modelContext.fetch(moveDescriptor)
        let fetchedPlaces = try modelContext.fetch(placeDescriptor)
        let fetchedSamples = try modelContext.fetch(sampleDescriptor)
        let moves = loadAll ? fetchedMoves : Array(fetchedMoves.prefix(TimelineDayPresentationLimits.maxLoadedMoves))
        let places = loadAll ? fetchedPlaces : Array(fetchedPlaces.prefix(TimelineDayPresentationLimits.maxLoadedPlaces))
        let samples = loadAll ? fetchedSamples : Array(fetchedSamples.prefix(TimelineDayPresentationLimits.maxLoadedSamples))
        // Keep exact summary counts without materializing records beyond the interactive cap.
        let totalMoveCount = try modelContext.fetchCount(FetchDescriptor(predicate: movePredicate))
        let totalSampleCount = try modelContext.fetchCount(FetchDescriptor(predicate: samplePredicate))
        var importedDescriptor = FetchDescriptor<LocationSample>(predicate: importedPredicate)
        importedDescriptor.fetchLimit = 1
        let hasImportedSamples = try !modelContext.fetch(importedDescriptor).isEmpty

        let resolution = MultiDeviceTimelineResolver.resolve(samples: samples)
        let visibleSamples = samples.filter { resolution.includes($0.deviceIdentifier) }
        let visibleMoves = moves.filter { resolution.includes($0.deviceIdentifier) }
        let visiblePlaces = places.filter { resolution.includes($0.deviceIdentifier) }

        var placeModelsByID = Dictionary(uniqueKeysWithValues: visiblePlaces.map { ($0.id, $0) })
        for move in visibleMoves {
            if let place = move.startPlace { placeModelsByID[place.id] = place }
            if let place = move.endPlace { placeModelsByID[place.id] = place }
        }
        let placeSnapshots = placeModelsByID.mapValues(TimelinePlaceSnapshot.init)

        var samplesByMoveID: [UUID: [LocationSample]] = [:]
        var sourceFlags: [UUID: UInt8] = [:]
        for sample in visibleSamples {
            guard let moveID = sample.moveSegment?.id else { continue }
            samplesByMoveID[moveID, default: []].append(sample)
            if sample.source.isRouteTrack { sourceFlags[moveID, default: 0] |= 1 << 1 }
            if sample.source == .healthWorkoutRoute { sourceFlags[moveID, default: 0] |= 1 << 2 }
            if sample.source == .fileRouteImport { sourceFlags[moveID, default: 0] |= 1 << 0 }
        }
        for (id, values) in samplesByMoveID {
            samplesByMoveID[id] = Self.routeSamples(values)
        }

        let moveSnapshots = visibleMoves.map { move in
            let routeSamples = samplesByMoveID[move.id] ?? []
            let isHealth = sourceFlags[move.id, default: 0] & (1 << 2) != 0
            let isImported = sourceFlags[move.id, default: 0] & (1 << 0) != 0
            if move.importedRouteData != nil { sourceFlags[move.id, default: 0] |= 1 << 0 }
            return TimelineMoveSnapshot(
                move,
                startPlace: move.startPlace.flatMap { placeSnapshots[$0.id] },
                endPlace: move.endPlace.flatMap { placeSnapshots[$0.id] },
                samples: routeSamples,
                usesImportedRoute: isImported,
                usesHealthWorkoutRoute: isHealth,
                usesRouteTracking: sourceFlags[move.id, default: 0] & (1 << 1) != 0
            )
        }
        let carriedOverPlace: TimelinePlaceSnapshot?
        if visibleMoves.isEmpty, visiblePlaces.isEmpty, totalSampleCount == 0 {
            var carriedDescriptor = FetchDescriptor<VisitPlace>(
                predicate: #Predicate { $0.arrivalDate < dayStart },
                sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
            )
            carriedDescriptor.fetchLimit = 1
            carriedOverPlace = try modelContext.fetch(carriedDescriptor).first.map(TimelinePlaceSnapshot.init)
        } else {
            carriedOverPlace = nil
        }

        let sampleSnapshots = visibleSamples.map(TimelineSampleSnapshot.init)
        let importedMoveIDs = Set(moveSnapshots.filter(\.usesImportedRoute).map(\.id))
        return TimelineDaySnapshot(
            places: Array(placeSnapshots.values),
            moves: moveSnapshots,
            samples: sampleSnapshots,
            sourcesByMoveID: sourceFlags,
            importedMoveIDs: importedMoveIDs,
            carriedOverPlace: carriedOverPlace,
            totalMoveCount: totalMoveCount,
            totalSampleCount: totalSampleCount,
            hasImportedRouteData: hasImportedSamples || importedMoveIDs.isEmpty == false
        )
    }

    private static func routeSamples(_ samples: [LocationSample]) -> [LocationSample] {
        guard samples.count > TimelineDayPresentationLimits.maxRouteSamplesPerMove else { return samples }
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let limit = TimelineDayPresentationLimits.maxRouteSamplesPerMove
        let step = Double(ordered.count - 1) / Double(limit - 1)
        return (0..<limit).map { ordered[Int((Double($0) * step).rounded())] }
    }
}
