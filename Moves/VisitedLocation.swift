import Foundation
import CoreLocation
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
    case launchBackfill
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
            let dedupeKey = Self.makeSampleDedupeKey(for: location, source: source)
            if let existing = try findSample(byDedupeKey: dedupeKey) {
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

    private static func makeSampleDedupeKey(for location: CLLocation, source: LocationSampleSource) -> String {
        let roundedSecond = Int(location.timestamp.timeIntervalSince1970.rounded())
        let roundedLat = roundedCoordinate(location.coordinate.latitude)
        let roundedLon = roundedCoordinate(location.coordinate.longitude)
        return "\(roundedSecond)|\(roundedLat)|\(roundedLon)|\(source.rawValue)"
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
