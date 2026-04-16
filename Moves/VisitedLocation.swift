import Foundation
import CoreLocation
import MapKit
import SwiftData

enum TransportMode: String, Codable, CaseIterable, Identifiable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stationary: return "Stationary"
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .automotive: return "Automotive"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .stationary: return "pause.circle.fill"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .automotive: return "car.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum LocationSampleSource: String, Codable, CaseIterable {
    case visit
    case significantChange
    case routeTracking
    case launchBackfill
    case authorizationGrant
}

extension LocationSampleSource {
    var priority: Int {
        switch self {
        case .routeTracking: return 4
        case .visit: return 3
        case .significantChange: return 2
        case .authorizationGrant: return 1
        case .launchBackfill: return 0
        }
    }
}

extension Array where Element == LocationSample {
    var preferredRouteDisplaySamples: [LocationSample] {
        let routeTrackingSamples = filter { $0.source == .routeTracking }
        return routeTrackingSamples.isEmpty ? self : routeTrackingSamples
    }
}

@Model
final class DayTimeline {
    var dayKey: String = ""
    var dayStart: Date = Date.now
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, originalName: "places", inverse: \VisitPlace.dayTimeline)
    var placesStorage: [VisitPlace]? = nil

    @Relationship(deleteRule: .cascade, originalName: "moves", inverse: \MoveSegment.dayTimeline)
    var movesStorage: [MoveSegment]? = nil

    @Relationship(deleteRule: .cascade, originalName: "samples", inverse: \LocationSample.dayTimeline)
    var samplesStorage: [LocationSample]? = nil

    var places: [VisitPlace] {
        get { placesStorage ?? [] }
        set { placesStorage = newValue }
    }

    var moves: [MoveSegment] {
        get { movesStorage ?? [] }
        set { movesStorage = newValue }
    }

    var samples: [LocationSample] {
        get { samplesStorage ?? [] }
        set { samplesStorage = newValue }
    }

    var uniqueLocationCount: Int {
        Set(places.map(\.locationKey)).count
    }

    init(dayStart: Date) {
        let start = Calendar.current.startOfDay(for: dayStart)
        self.dayStart = start
        self.dayKey = DayTimeline.makeDayKey(for: start)
        self.createdAt = .now
    }

    static func makeDayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: Calendar.current.startOfDay(for: date))
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@Model
final class VisitPlace {
    var id: UUID = UUID()
    var arrivalDate: Date = Date.now
    var departureDate: Date? = nil
    var latitude: Double = 0
    var longitude: Double = 0
    var horizontalAccuracy: Double = 0
    var userLabel: String? = nil
    var autoLabel: String? = nil
    var createdAt: Date = Date.now

    var dayTimeline: DayTimeline?

    @Relationship(originalName: "outgoingMoves", inverse: \MoveSegment.startPlace)
    var outgoingMovesStorage: [MoveSegment]? = nil

    @Relationship(originalName: "incomingMoves", inverse: \MoveSegment.endPlace)
    var incomingMovesStorage: [MoveSegment]? = nil

    var outgoingMoves: [MoveSegment] {
        get { outgoingMovesStorage ?? [] }
        set { outgoingMovesStorage = newValue }
    }

    var incomingMoves: [MoveSegment] {
        get { incomingMovesStorage ?? [] }
        set { incomingMovesStorage = newValue }
    }

    init(
        arrivalDate: Date,
        departureDate: Date?,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        userLabel: String? = nil,
        autoLabel: String? = nil
    ) {
        self.id = UUID()
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.userLabel = userLabel
        self.autoLabel = autoLabel
        self.createdAt = .now
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayTitle: String {
        if let userLabel, !userLabel.isEmpty {
            return userLabel
        }
        if let autoLabel, !autoLabel.isEmpty {
            return autoLabel
        }

        let lat = String(format: "%.5f", latitude)
        let lon = String(format: "%.5f", longitude)
        return "\(lat), \(lon)"
    }
}

fileprivate extension VisitPlace {
    var locationKey: String {
        // Round into ~10m buckets so repeat visits to the same spot count once.
        let latitudeBucket = Int((latitude * 10_000).rounded())
        let longitudeBucket = Int((longitude * 10_000).rounded())
        return "\(latitudeBucket)|\(longitudeBucket)"
    }
}

@Model
final class MoveSegment {
    var id: UUID = UUID()
    var dedupeKey: String = ""
    var startDate: Date = Date.now
    var endDate: Date = Date.now
    var transportModeRawValue: String = TransportMode.unknown.rawValue
    var distanceMeters: Double = 0
    var stepCount: Int? = nil
    var createdAt: Date = Date.now

    var startPlace: VisitPlace?
    var endPlace: VisitPlace?
    var dayTimeline: DayTimeline?
    var routeCacheSignature: String? = nil
    var routeCacheCoordinatesData: Data? = nil

    @Relationship(deleteRule: .nullify, originalName: "samples", inverse: \LocationSample.moveSegment)
    var samplesStorage: [LocationSample]? = nil

    var samples: [LocationSample] {
        get { samplesStorage ?? [] }
        set { samplesStorage = newValue }
    }

    init(
        dedupeKey: String,
        startDate: Date,
        endDate: Date,
        transportMode: TransportMode,
        distanceMeters: Double,
        stepCount: Int?
    ) {
        self.id = UUID()
        self.dedupeKey = dedupeKey
        self.startDate = startDate
        self.endDate = endDate
        self.transportModeRawValue = transportMode.rawValue
        self.distanceMeters = distanceMeters
        self.stepCount = stepCount
        self.createdAt = .now
    }

    var transportMode: TransportMode {
        get { TransportMode(rawValue: transportModeRawValue) ?? .unknown }
        set { transportModeRawValue = newValue.rawValue }
    }

    var timelineStartDate: Date {
        let departureBasedStart = startPlace?.departureDate ?? startDate
        let normalizedStart = max(departureBasedStart, startDate)
        return min(normalizedStart, endDate)
    }

    var timelineDuration: TimeInterval {
        max(endDate.timeIntervalSince(timelineStartDate), 0)
    }

    var usesHighAccuracyRouteTracking: Bool {
        samples.contains { $0.source == .routeTracking }
    }

    func cachedRouteCoordinates(for signature: String) -> [CLLocationCoordinate2D]? {
        guard routeCacheSignature == signature, routeCacheCoordinatesData != nil else {
            return nil
        }

        return RouteCoordinateStorage.decode(routeCacheCoordinatesData)
    }

    func storeCachedRouteCoordinates(_ coordinates: [CLLocationCoordinate2D], signature: String) {
        routeCacheSignature = signature
        routeCacheCoordinatesData = RouteCoordinateStorage.encode(coordinates)
    }

    func clearCachedRouteCoordinates() {
        routeCacheSignature = nil
        routeCacheCoordinatesData = nil
    }
}

@Model
final class LocationSample {
    var dedupeKey: String = ""
    var timestamp: Date = Date.now
    var latitude: Double = 0
    var longitude: Double = 0
    var altitude: Double = 0
    var horizontalAccuracy: Double = 0
    var speed: Double = 0
    var sourceRawValue: String = LocationSampleSource.significantChange.rawValue
    var createdAt: Date = Date.now

    var dayTimeline: DayTimeline?
    var moveSegment: MoveSegment?

    init(location: CLLocation, source: LocationSampleSource, dedupeKey: String) {
        self.dedupeKey = dedupeKey
        self.timestamp = location.timestamp
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.speed = location.speed
        self.sourceRawValue = source.rawValue
        self.createdAt = .now
    }

    var source: LocationSampleSource {
        get { LocationSampleSource(rawValue: sourceRawValue) ?? .significantChange }
        set { sourceRawValue = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var asLocation: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            course: -1,
            speed: speed,
            timestamp: timestamp
        )
    }
}

@MainActor
protocol TimelineRepository {
    func addOrUpdateVisit(from visit: CLVisit) throws -> VisitPlace
    func appendSamples(from locations: [CLLocation], source: LocationSampleSource) throws -> [LocationSample]
    func latestPlace(before date: Date, excluding placeID: UUID?) throws -> VisitPlace?
    func samples(from startDate: Date, to endDate: Date) throws -> [LocationSample]
    func upsertMove(
        startPlace: VisitPlace,
        endPlace: VisitPlace,
        startDate: Date,
        endDate: Date,
        transportMode: TransportMode,
        distanceMeters: Double,
        stepCount: Int?,
        samples: [LocationSample]
    ) throws -> MoveSegment
    func setAutomaticLabel(_ label: String, for placeID: UUID) throws
    func saveIfNeeded() throws
}

@MainActor
final class SwiftDataTimelineRepository: TimelineRepository {
    private let modelContext: ModelContext
    private static let sampleDedupeTimeWindow: TimeInterval = 5 * 60
    private static let sampleDedupeDistanceThreshold: CLLocationDistance = 120

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
    }

    func addOrUpdateVisit(from visit: CLVisit) throws -> VisitPlace {
        let arrival = normalizedArrivalDate(for: visit)
        let departure = normalizedDepartureDate(for: visit)

        let existing = try existingVisit(near: arrival, coordinate: visit.coordinate)
        if let existing {
            if let departure {
                existing.departureDate = departure
            }
            existing.horizontalAccuracy = min(existing.horizontalAccuracy, visit.horizontalAccuracy)
            existing.dayTimeline = try timeline(for: arrival)
            try saveIfNeeded()
            return existing
        }

        let inferredUserLabel = try inferredUserLabel(near: visit.coordinate)

        let place = VisitPlace(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude,
            horizontalAccuracy: visit.horizontalAccuracy,
            userLabel: inferredUserLabel
        )
        place.dayTimeline = try timeline(for: arrival)
        modelContext.insert(place)
        try saveIfNeeded()
        return place
    }

    func appendSamples(from locations: [CLLocation], source: LocationSampleSource) throws -> [LocationSample] {
        guard !locations.isEmpty else { return [] }

        var inserted: [LocationSample] = []
        inserted.reserveCapacity(locations.count)

        for location in locations {
            let dedupeKey = Self.makeSampleDedupeKey(for: location)
            if let existing = try findSample(byDedupeKey: dedupeKey) ?? findNearbySample(matching: location) {
                existing.source = Self.preferredSource(existing: existing.source, new: source)
                inserted.append(existing)
                continue
            }

            let sample = LocationSample(location: location, source: source, dedupeKey: dedupeKey)
            sample.dayTimeline = try timeline(for: location.timestamp)
            modelContext.insert(sample)
            inserted.append(sample)
        }

        try saveIfNeeded()
        return inserted
    }

    func latestPlace(before date: Date, excluding placeID: UUID?) throws -> VisitPlace? {
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate < date
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        descriptor.fetchLimit = 24

        let candidates = try modelContext.fetch(descriptor)
        return candidates.first {
            $0.id != placeID && ($0.departureDate ?? $0.arrivalDate) < date
        }
    }

    func samples(from startDate: Date, to endDate: Date) throws -> [LocationSample] {
        guard startDate <= endDate else { return [] }

        let descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { sample in
                sample.timestamp >= startDate && sample.timestamp <= endDate
            },
            sortBy: [SortDescriptor(\LocationSample.timestamp, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }

    func upsertMove(
        startPlace: VisitPlace,
        endPlace: VisitPlace,
        startDate: Date,
        endDate: Date,
        transportMode: TransportMode,
        distanceMeters: Double,
        stepCount: Int?,
        samples: [LocationSample]
    ) throws -> MoveSegment {
        let dedupeKey = Self.makeMoveDedupeKey(
            startPlaceID: startPlace.id,
            endPlaceID: endPlace.id,
            startDate: startDate,
            endDate: endDate
        )

        let timeline = try timeline(for: startDate)

        let move: MoveSegment
        if let existing = try findMove(byDedupeKey: dedupeKey)
            ?? findMove(startPlaceID: startPlace.id, endPlaceID: endPlace.id) {
            move = existing
            move.dedupeKey = dedupeKey
            move.transportMode = transportMode
            move.distanceMeters = distanceMeters
            move.stepCount = stepCount
            move.startDate = startDate
            move.endDate = endDate
        } else {
            move = MoveSegment(
                dedupeKey: dedupeKey,
                startDate: startDate,
                endDate: endDate,
                transportMode: transportMode,
                distanceMeters: distanceMeters,
                stepCount: stepCount
            )
            modelContext.insert(move)
        }

        move.startPlace = startPlace
        move.endPlace = endPlace
        move.dayTimeline = timeline

        for sample in samples {
            sample.moveSegment = move
        }

        try saveIfNeeded()
        return move
    }

    func setAutomaticLabel(_ label: String, for placeID: UUID) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.id == placeID
            }
        )
        descriptor.fetchLimit = 1

        guard let place = try modelContext.fetch(descriptor).first else {
            return
        }

        if let userLabel = place.userLabel, !userLabel.isEmpty {
            return
        }
        if let existingAuto = place.autoLabel, !existingAuto.isEmpty {
            return
        }

        place.autoLabel = trimmed
        try saveIfNeeded()
    }

    func saveIfNeeded() throws {
        guard modelContext.hasChanges else { return }
        try modelContext.save()
    }

    private func timeline(for date: Date) throws -> DayTimeline {
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayKey = DayTimeline.makeDayKey(for: dayStart)

        var descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { timeline in
                timeline.dayKey == dayKey
            }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }

        let timeline = DayTimeline(dayStart: dayStart)
        modelContext.insert(timeline)
        return timeline
    }

    private func existingVisit(near arrivalDate: Date, coordinate: CLLocationCoordinate2D) throws -> VisitPlace? {
        let windowStart = arrivalDate.addingTimeInterval(-120)
        let windowEnd = arrivalDate.addingTimeInterval(120)

        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.arrivalDate >= windowStart && place.arrivalDate <= windowEnd
            },
            sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
        )
        descriptor.fetchLimit = 8

        let candidates = try modelContext.fetch(descriptor)
        return candidates.first {
            Self.distanceMeters(
                from: coordinate,
                to: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            ) < 80
        }
    }

    private func findSample(byDedupeKey dedupeKey: String) throws -> LocationSample? {
        var descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { sample in
                sample.dedupeKey == dedupeKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func findNearbySample(matching location: CLLocation) throws -> LocationSample? {
        let windowStart = location.timestamp.addingTimeInterval(-Self.sampleDedupeTimeWindow)
        let windowEnd = location.timestamp.addingTimeInterval(Self.sampleDedupeTimeWindow)

        var descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { sample in
                sample.timestamp >= windowStart && sample.timestamp <= windowEnd
            },
            sortBy: [SortDescriptor(\LocationSample.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 24

        let candidates = try modelContext.fetch(descriptor)
        return candidates.first {
            Self.distanceMeters(
                from: location.coordinate,
                to: $0.coordinate
            ) <= Self.sampleDedupeDistanceThreshold
        }
    }

    private func findMove(byDedupeKey dedupeKey: String) throws -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.dedupeKey == dedupeKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func findMove(startPlaceID: UUID, endPlaceID: UUID) throws -> MoveSegment? {
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: #Predicate { move in
                move.startPlace?.id == startPlaceID && move.endPlace?.id == endPlaceID
            },
            sortBy: [SortDescriptor(\MoveSegment.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func normalizedArrivalDate(for visit: CLVisit) -> Date {
        if visit.arrivalDate == .distantPast {
            if let departure = normalizedDepartureDate(for: visit) {
                return departure.addingTimeInterval(-300)
            }
            return .now
        }
        return visit.arrivalDate
    }

    private func normalizedDepartureDate(for visit: CLVisit) -> Date? {
        if visit.departureDate == .distantFuture {
            return nil
        }
        return visit.departureDate
    }

    private static func makeSampleDedupeKey(for location: CLLocation) -> String {
        let roundedSecond = Int(location.timestamp.timeIntervalSince1970.rounded())
        let roundedLat = roundedCoordinate(location.coordinate.latitude)
        let roundedLon = roundedCoordinate(location.coordinate.longitude)
        return "\(roundedSecond)|\(roundedLat)|\(roundedLon)"
    }

    private static func makeMoveDedupeKey(
        startPlaceID: UUID,
        endPlaceID: UUID,
        startDate: Date,
        endDate: Date
    ) -> String {
        let startSeconds = Int(startDate.timeIntervalSince1970.rounded())
        let endSeconds = Int(endDate.timeIntervalSince1970.rounded())
        return "\(startPlaceID.uuidString)|\(endPlaceID.uuidString)|\(startSeconds)|\(endSeconds)"
    }

    private static func roundedCoordinate(_ value: Double) -> String {
        String(format: "%.5f", value)
    }

    private static func preferredSource(
        existing: LocationSampleSource,
        new: LocationSampleSource
    ) -> LocationSampleSource {
        return new.priority > existing.priority ? new : existing
    }

    private func inferredUserLabel(near coordinate: CLLocationCoordinate2D) throws -> String? {
        let descriptor = FetchDescriptor<VisitPlace>(
            predicate: #Predicate { place in
                place.userLabel != nil
            }
        )

        let labeledPlaces = try modelContext.fetch(descriptor)

        let nearest = labeledPlaces
            .compactMap { place -> (String, CLLocationDistance)? in
                guard let label = place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                    return nil
                }

                let distance = Self.distanceMeters(
                    from: coordinate,
                    to: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                )
                return (label, distance)
            }
            .filter { $0.1 <= 120 }
            .min(by: { $0.1 < $1.1 })

        return nearest?.0
    }

    private static func distanceMeters(from lhs: CLLocationCoordinate2D, to rhs: CLLocationCoordinate2D) -> CLLocationDistance {
        let left = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let right = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return left.distance(from: right)
    }
}

#if targetEnvironment(simulator)
enum SimulatorDemoDataSeeder {
    private static var roadCoordinatesCache: [String: [CLLocationCoordinate2D]] = [:]
    private static var roadCoordinatesRequestCount = 0
    private static let roadCoordinatesRequestLimit = 20

    static func seedIfNeeded(in container: ModelContainer) {
        do {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<DayTimeline>()

            guard try context.fetch(descriptor).isEmpty else {
                return
            }

            Task { @MainActor in
                do {
                    let context = ModelContext(container)
                    try await seed(in: context)
                } catch {
                    print("Failed to seed simulator demo data: \(error.localizedDescription)")
                }
            }
        } catch {
            print("Failed to seed simulator demo data: \(error.localizedDescription)")
        }
    }

    private static func seed(in context: ModelContext) async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        for (index, route) in demoRoutes.enumerated() {
            let dayOffset = demoRoutes.count - index - 1
            guard let dayStart = calendar.date(byAdding: .day, value: -dayOffset, to: today) else {
                continue
            }

            try await seed(route: route, routeIndex: index, dayStart: dayStart, calendar: calendar, context: context)
        }

        try context.save()
    }

    private static func seed(
        route: RouteBlueprint,
        routeIndex: Int,
        dayStart: Date,
        calendar: Calendar,
        context: ModelContext
    ) async throws {
        let timeline = DayTimeline(dayStart: dayStart)
        context.insert(timeline)

        let plannedStops = plannedStops(for: route)
        guard let firstMode = plannedStops.first?.transportMode else {
            return
        }

        guard let routeStart = calendar.date(
            byAdding: .minute,
            value: startOffsetMinutes(for: firstMode, routeIndex: routeIndex),
            to: dayStart
        ) else {
            return
        }

        var currentTime = routeStart
        var places: [VisitPlace] = []
        var pendingMoves: [PendingMove] = []

        for (stopIndex, plannedStop) in plannedStops.enumerated() {
            let dwellMinutes = dwellMinutes(for: routeIndex, stopIndex: stopIndex)
            let arrival = currentTime
            let departure = arrival.addingTimeInterval(TimeInterval(dwellMinutes * 60))

            let place = VisitPlace(
                arrivalDate: arrival,
                departureDate: departure,
                latitude: plannedStop.stop.coordinate.latitude,
                longitude: plannedStop.stop.coordinate.longitude,
                horizontalAccuracy: horizontalAccuracy(for: plannedStop.transportMode),
                userLabel: plannedStop.stop.label
            )
            place.dayTimeline = timeline
            context.insert(place)
            places.append(place)

            currentTime = departure

            guard stopIndex < plannedStops.count - 1 else {
                continue
            }

            let nextStop = plannedStops[stopIndex + 1]
            let legGeometry = await makeLegGeometry(
                from: plannedStop.stop.coordinate,
                to: nextStop.stop.coordinate,
                routeIndex: routeIndex,
                legIndex: stopIndex,
                mode: nextStop.transportMode
            )
            let travelDurationMinutes = travelDurationMinutes(
                for: legGeometry.distanceMeters,
                mode: nextStop.transportMode
            )
            let moveStart = departure
            let moveEnd = departure.addingTimeInterval(TimeInterval(travelDurationMinutes * 60))
            let samples = makeSamples(
                from: legGeometry.coordinates,
                moveStart: moveStart,
                moveEnd: moveEnd,
                routeIndex: routeIndex,
                legIndex: stopIndex,
                mode: nextStop.transportMode
            )

            pendingMoves.append(
                PendingMove(
                    startIndex: stopIndex,
                    endIndex: stopIndex + 1,
                    startDate: moveStart,
                    endDate: moveEnd,
                    transportMode: nextStop.transportMode,
                    distanceMeters: legGeometry.distanceMeters,
                    stepCount: stepCount(for: legGeometry.distanceMeters, mode: nextStop.transportMode),
                    samples: samples
                )
            )

            currentTime = moveEnd
        }

        for (moveIndex, pendingMove) in pendingMoves.enumerated() {
            let move = MoveSegment(
                dedupeKey: moveDedupeKey(
                    routeIndex: routeIndex,
                    moveIndex: moveIndex,
                    startDate: pendingMove.startDate,
                    endDate: pendingMove.endDate
                ),
                startDate: pendingMove.startDate,
                endDate: pendingMove.endDate,
                transportMode: pendingMove.transportMode,
                distanceMeters: pendingMove.distanceMeters,
                stepCount: pendingMove.stepCount
            )
            move.startPlace = places[pendingMove.startIndex]
            move.endPlace = places[pendingMove.endIndex]
            move.dayTimeline = timeline
            context.insert(move)

            for sample in pendingMove.samples {
                sample.dayTimeline = timeline
                sample.moveSegment = move
                context.insert(sample)
            }
        }
    }

    private static func makeLegGeometry(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        routeIndex: Int,
        legIndex: Int,
        mode: TransportMode
    ) async -> LegGeometry {
        let directDistance = distanceMeters(from: start, to: end)
        let sampleCount = max(4, min(7, Int(directDistance / 850) + 4))
        let bendDirection = ((routeIndex + legIndex) % 2 == 0) ? 1.0 : -1.0
        let bendStrength = 0.10 + Double((routeIndex + legIndex) % 3) * 0.03

        let pathCoordinates = await roadCoordinates(
            from: start,
            to: end,
            mode: mode
        ) ?? curvedPoints(
            from: start,
            to: end,
            count: sampleCount,
            bendDirection: bendDirection,
            bendStrength: bendStrength
        )

        let coordinates = sampleCoordinates(
            from: pathCoordinates,
            maximumCount: sampleCount
        )
        let distanceMeters = pathDistance(for: [start] + pathCoordinates + [end])

        return LegGeometry(coordinates: coordinates, distanceMeters: distanceMeters)
    }

    private static func makeSamples(
        from coordinates: [CLLocationCoordinate2D],
        moveStart: Date,
        moveEnd: Date,
        routeIndex: Int,
        legIndex: Int,
        mode: TransportMode
    ) -> [LocationSample] {
        guard !coordinates.isEmpty else { return [] }

        let duration = moveEnd.timeIntervalSince(moveStart)
        let sampleSpeed = speedMetersPerSecond(for: mode)

        return coordinates.enumerated().map { index, coordinate in
            let fraction = Double(index + 1) / Double(coordinates.count + 1)
            let timestamp = moveStart.addingTimeInterval(duration * fraction)
            let location = CLLocation(
                coordinate: coordinate,
                altitude: 0,
                horizontalAccuracy: horizontalAccuracy(for: mode),
                verticalAccuracy: -1,
                course: -1,
                speed: sampleSpeed,
                timestamp: timestamp
            )

            return LocationSample(
                location: location,
                source: .significantChange,
                dedupeKey: "demo-leg-\(routeIndex)-\(legIndex)-\(index)"
            )
        }
    }

    private static func roadCoordinates(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TransportMode
    ) async -> [CLLocationCoordinate2D]? {
        let cacheKey = roadCoordinatesCacheKey(from: start, to: end, mode: mode)
        if let cached = roadCoordinatesCache[cacheKey] {
            return cached
        }

        guard roadCoordinatesRequestCount < roadCoordinatesRequestLimit else {
            return nil
        }

        guard let transportType = mapTransportType(for: mode) else {
            return nil
        }

        roadCoordinatesRequestCount += 1

        let request = MKDirections.Request()
        request.source = mapItem(for: start)
        request.destination = mapItem(for: end)
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                return nil
            }

            let coordinates = polylineCoordinates(route.polyline)
            guard coordinates.count > 1 else {
                return nil
            }

            roadCoordinatesCache[cacheKey] = coordinates
            return coordinates
        } catch {
            return nil
        }
    }

    private static func roadCoordinatesCacheKey(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TransportMode
    ) -> String {
        [
            mode.rawValue,
            String(format: "%.4f", start.latitude),
            String(format: "%.4f", start.longitude),
            String(format: "%.4f", end.latitude),
            String(format: "%.4f", end.longitude)
        ]
        .joined(separator: "|")
    }

    private static func curvedPoints(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        count: Int,
        bendDirection: Double,
        bendStrength: Double
    ) -> [CLLocationCoordinate2D] {
        guard count > 0 else { return [] }

        let latDelta = end.latitude - start.latitude
        let lonDelta = end.longitude - start.longitude
        let scale = max(abs(latDelta), abs(lonDelta))
        let perpendicularLat = -lonDelta
        let perpendicularLon = latDelta

        return (1...count).map { index in
            let t = Double(index) / Double(count + 1)
            let wave = sin(.pi * t)
            let offset = scale * bendStrength * wave * bendDirection

            return CLLocationCoordinate2D(
                latitude: start.latitude + (latDelta * t) + (perpendicularLat * offset),
                longitude: start.longitude + (lonDelta * t) + (perpendicularLon * offset)
            )
        }
    }

    private static func sampleCoordinates(
        from coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount, maximumCount > 1 else {
            return coordinates
        }

        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            let rawIndex = Int((Double(index) * step).rounded(.toNearestOrAwayFromZero))
            return coordinates[min(rawIndex, coordinates.count - 1)]
        }
    }

    private static func polylineCoordinates(_ polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        guard polyline.pointCount > 0 else { return [] }

        var coordinates = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }

    private static func pathDistance(for coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count > 1 else { return 0 }

        return zip(coordinates, coordinates.dropFirst()).reduce(0) { partialResult, pair in
            partialResult + distanceMeters(from: pair.0, to: pair.1)
        }
    }

    private static func distanceMeters(
        from lhs: CLLocationCoordinate2D,
        to rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let left = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let right = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return left.distance(from: right)
    }

    private static func travelDurationMinutes(
        for distanceMeters: CLLocationDistance,
        mode: TransportMode
    ) -> Int {
        let metersPerMinute: Double
        let minimumMinutes: Int

        switch mode {
        case .walking:
            metersPerMinute = 85
            minimumMinutes = 12
        case .running:
            metersPerMinute = 180
            minimumMinutes = 8
        case .cycling:
            metersPerMinute = 260
            minimumMinutes = 10
        case .automotive:
            metersPerMinute = 700
            minimumMinutes = 12
        case .stationary, .unknown:
            metersPerMinute = 85
            minimumMinutes = 12
        }

        let estimatedMinutes = Int((distanceMeters / metersPerMinute).rounded(.up))
        return max(estimatedMinutes, minimumMinutes)
    }

    private static func stepCount(
        for distanceMeters: CLLocationDistance,
        mode: TransportMode
    ) -> Int? {
        switch mode {
        case .walking:
            return max(Int((distanceMeters / 0.76).rounded()), 0)
        case .running:
            return max(Int((distanceMeters / 1.02).rounded()), 0)
        case .cycling, .automotive, .stationary, .unknown:
            return nil
        }
    }

    private static func speedMetersPerSecond(for mode: TransportMode) -> Double {
        switch mode {
        case .walking:
            return 1.4
        case .running:
            return 3.0
        case .cycling:
            return 4.6
        case .automotive:
            return 11.5
        case .stationary, .unknown:
            return 1.0
        }
    }

    private static func horizontalAccuracy(for mode: TransportMode) -> Double {
        switch mode {
        case .walking, .running:
            return 16
        case .cycling:
            return 20
        case .automotive:
            return 24
        case .stationary, .unknown:
            return 18
        }
    }

    private static func startOffsetMinutes(
        for mode: TransportMode,
        routeIndex: Int
    ) -> Int {
        let baseMinutes: Int

        switch mode {
        case .running:
            baseMinutes = 6 * 60 + 40
        case .walking:
            baseMinutes = 8 * 60 + 15
        case .cycling:
            baseMinutes = 9 * 60 + 5
        case .automotive:
            baseMinutes = 10 * 60 + 20
        case .stationary, .unknown:
            baseMinutes = 8 * 60
        }

        return baseMinutes + ((routeIndex % 3) * 14)
    }

    private static func dwellMinutes(
        for routeIndex: Int,
        stopIndex: Int
    ) -> Int {
        let pattern = [24, 36, 28, 42]
        return pattern[(routeIndex + stopIndex) % pattern.count]
    }

    private static func moveDedupeKey(
        routeIndex: Int,
        moveIndex: Int,
        startDate: Date,
        endDate: Date
    ) -> String {
        let startSeconds = Int(startDate.timeIntervalSince1970.rounded())
        let endSeconds = Int(endDate.timeIntervalSince1970.rounded())
        return "demo|\(routeIndex)|\(moveIndex)|\(startSeconds)|\(endSeconds)"
    }

    private static func route(
        _ title: String,
        mode: TransportMode,
        _ stops: [RouteStop]
    ) -> RouteBlueprint {
        RouteBlueprint(title: title, stages: [stage(mode, stops)])
    }

    private static func route(
        _ title: String,
        stages: [RouteStage]
    ) -> RouteBlueprint {
        RouteBlueprint(title: title, stages: stages)
    }

    private static func stage(
        _ mode: TransportMode,
        _ stops: [RouteStop]
    ) -> RouteStage {
        RouteStage(transportMode: mode, stops: stops)
    }

    private static func plannedStops(for route: RouteBlueprint) -> [PlannedStop] {
        route.stages.flatMap { stage in
            stage.stops.map { stop in
                PlannedStop(stop: stop, transportMode: stage.transportMode)
            }
        }
    }

    private static func stop(
        _ label: String,
        _ latitude: Double,
        _ longitude: Double
    ) -> RouteStop {
        RouteStop(
            label: label,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    private static let demoRoutes: [RouteBlueprint] = [
        route(
            "Amsterdam Canal Ring Cycle",
            mode: .cycling,
            [
                stop("Rijksmuseum", 52.359997, 4.885218),
                stop("Vondelpark", 52.358400, 4.868500),
                stop("De Hallen", 52.367200, 4.873300),
                stop("NDSM Wharf", 52.408400, 4.894900)
            ]
        ),
        route(
            "Paris Left Bank Drift",
            mode: .walking,
            [
                stop("Jardin du Luxembourg", 48.846200, 2.337200),
                stop("Shakespeare and Company", 48.852800, 2.347000),
                stop("Musee d'Orsay", 48.860000, 2.326600),
                stop("Eiffel Tower", 48.858400, 2.294500)
            ]
        ),
        route(
            "London South Bank Loop",
            mode: .walking,
            [
                stop("Tower Bridge", 51.505500, -0.075400),
                stop("Tate Modern", 51.507600, -0.099400),
                stop("Covent Garden", 51.512900, -0.124800),
                stop("Regent's Park", 51.531300, -0.156900)
            ]
        ),
        route(
            "Barcelona Coast and Crest",
            mode: .cycling,
            [
                stop("Sagrada Familia", 41.403600, 2.174400),
                stop("Gothic Quarter", 41.383900, 2.176000),
                stop("Barceloneta", 41.378500, 2.192900),
                stop("Park Guell", 41.414500, 2.152700)
            ]
        ),
        route(
            "Rome Ancient-to-River Walk",
            mode: .walking,
            [
                stop("Colosseum", 41.890200, 12.492200),
                stop("Piazza Venezia", 41.895500, 12.482300),
                stop("Trastevere", 41.889500, 12.470800),
                stop("Vatican Museums", 41.906500, 12.453600)
            ]
        ),
        route(
            "Copenhagen Harbor Hop",
            mode: .cycling,
            [
                stop("Nyhavn", 55.679800, 12.589200),
                stop("Christianshavn", 55.673600, 12.599900),
                stop("Designmuseum Danmark", 55.692900, 12.581900),
                stop("CopenHill", 55.696000, 12.589400)
            ]
        ),
        route(
            "New York High Line Circuit",
            mode: .walking,
            [
                stop("Hudson Yards", 40.754000, -74.001800),
                stop("Chelsea Market", 40.742300, -74.006000),
                stop("The Met", 40.779400, -73.963200),
                stop("Central Park South", 40.766100, -73.977600)
            ]
        ),
        route(
            "Tokyo Neon Loop",
            mode: .walking,
            [
                stop("Shibuya Crossing", 35.659500, 139.700500),
                stop("Meiji Jingu", 35.676400, 139.699300),
                stop("Akihabara", 35.698400, 139.773000),
                stop("Asakusa Senso-ji", 35.714800, 139.796700)
            ]
        ),
        route(
            "Kyoto Temple Run",
            mode: .running,
            [
                stop("Arashiyama Bamboo Grove", 35.009400, 135.671800),
                stop("Tenryu-ji", 35.016900, 135.670400),
                stop("Kinkaku-ji", 35.039400, 135.729200),
                stop("Fushimi Inari", 34.967100, 135.772700)
            ]
        ),
        route(
            "Singapore Bay Orbit",
            mode: .walking,
            [
                stop("Gardens by the Bay", 1.281600, 103.863600),
                stop("Marina Bay Sands", 1.283400, 103.860000),
                stop("Chinatown", 1.283700, 103.843100),
                stop("Little India", 1.306600, 103.849500)
            ]
        ),
        route(
            "San Francisco Hills Tour",
            mode: .cycling,
            [
                stop("Ferry Building", 37.795500, -122.393700),
                stop("Coit Tower", 37.802400, -122.405800),
                stop("Lombard Street", 37.802100, -122.418700),
                stop("Golden Gate Bridge Vista", 37.819900, -122.478300)
            ]
        ),
        route(
            "Kona Ironman Bike + Marathon",
            stages: [
                stage(
                    .cycling,
                    [
                        stop("Kailua Pier", 19.639400, -155.996000),
                        stop("Queen K Highway", 19.623500, -155.972000),
                        stop("Keauhou Bay", 19.558000, -155.964800),
                        stop("Waikoloa Beach", 19.938600, -155.859000),
                        stop("Hawi Turnaround", 20.239600, -155.822200),
                        stop("T2 / Kailua Pier", 19.639400, -155.996000)
                    ]
                ),
                stage(
                    .running,
                    [
                        stop("Alii Drive Sunrise", 19.637900, -155.989300),
                        stop("Natural Energy Lab", 19.615200, -155.987400),
                        stop("Palani Road Climb", 19.643300, -155.980900),
                        stop("Kailua Pier Finish", 19.639400, -155.996000)
                    ]
                )
            ]
        ),
        route(
            "Las Vegas Heist Escape",
            mode: .automotive,
            [
                stop("Bellagio", 36.112600, -115.177100),
                stop("Caesars Palace", 36.116300, -115.174500),
                stop("The Venetian", 36.121100, -115.171300),
                stop("Fremont Street", 36.170900, -115.140900),
                stop("Harry Reid Airport", 36.084000, -115.153700)
            ]
        ),
        route(
            "Istanbul Bosphorus Crossing",
            mode: .walking,
            [
                stop("Hagia Sophia", 41.008600, 28.980200),
                stop("Grand Bazaar", 41.010500, 28.968000),
                stop("Galata Bridge", 41.019800, 28.973500),
                stop("Kadikoy Pier", 40.990900, 29.026200)
            ]
        ),
        route(
            "Mexico City Culture Arc",
            mode: .cycling,
            [
                stop("Zocalo", 19.432600, -99.133200),
                stop("Alameda Central", 19.435200, -99.141500),
                stop("Chapultepec", 19.420400, -99.181200),
                stop("Coyoacan", 19.349900, -99.162100)
            ]
        ),
        route(
            "Rio Skyline Loop",
            mode: .automotive,
            [
                stop("Copacabana", -22.971100, -43.182200),
                stop("Sugarloaf", -22.948600, -43.158300),
                stop("Santa Teresa", -22.917700, -43.189700),
                stop("Christ the Redeemer", -22.951900, -43.210500)
            ]
        ),
        route(
            "Monaco Grand Prix Circuit",
            mode: .automotive,
            [
                stop("Casino Square", 43.739700, 7.428900),
                stop("Fairmont Hairpin", 43.737000, 7.430600),
                stop("Tunnel", 43.734500, 7.426900),
                stop("Port Hercule", 43.733000, 7.421000),
                stop("Tabac Corner", 43.732000, 7.423300),
                stop("La Rascasse", 43.731300, 7.424900)
            ]
        ),
        route(
            "Boston Marathon Finish Push",
            mode: .running,
            [
                stop("Hopkinton Center", 42.215000, -71.515000),
                stop("Wellesley College", 42.295000, -71.292000),
                stop("Heartbreak Hill", 42.333300, -71.212000),
                stop("Boston College", 42.335200, -71.168000),
                stop("Kenmore Square", 42.348000, -71.095000),
                stop("Copley Square", 42.350600, -71.076000)
            ]
        ),
        route(
            "Seoul Palace-to-River Loop",
            mode: .walking,
            [
                stop("Gyeongbokgung", 37.579600, 126.977000),
                stop("Insadong", 37.574000, 126.986400),
                stop("Dongdaemun Design Plaza", 37.566400, 127.009600),
                stop("Banpo Bridge", 37.516500, 126.996300)
            ]
        ),
        route(
            "Sydney Harbour Sweep",
            mode: .running,
            [
                stop("Circular Quay", -33.861100, 151.210900),
                stop("Opera House", -33.856800, 151.215300),
                stop("Royal Botanic Garden", -33.864700, 151.216800),
                stop("Bondi Beach", -33.890800, 151.274300)
            ]
        )
    ]

    private struct RouteBlueprint {
        let title: String
        let stages: [RouteStage]
    }

    private struct RouteStage {
        let transportMode: TransportMode
        let stops: [RouteStop]
    }

    private struct RouteStop {
        let label: String
        let coordinate: CLLocationCoordinate2D
    }

    private struct PlannedStop {
        let stop: RouteStop
        let transportMode: TransportMode
    }

    private struct PendingMove {
        let startIndex: Int
        let endIndex: Int
        let startDate: Date
        let endDate: Date
        let transportMode: TransportMode
        let distanceMeters: CLLocationDistance
        let stepCount: Int?
        let samples: [LocationSample]
    }

    private struct LegGeometry {
        let coordinates: [CLLocationCoordinate2D]
        let distanceMeters: CLLocationDistance
    }

    private static func mapItem(for coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #unavailable(iOS 26.0) {
            return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return MKMapItem(location: location, address: nil)
    }

    private static func mapTransportType(for mode: TransportMode) -> MKDirectionsTransportType? {
        switch mode {
        case .automotive:
            return .automobile
        case .walking, .running:
            return .walking
        case .cycling:
            return .cycling
        case .stationary, .unknown:
            return nil
        }
    }
}
#endif
