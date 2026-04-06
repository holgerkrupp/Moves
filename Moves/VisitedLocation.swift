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
    @Attribute(.unique) var dayKey: String
    var dayStart: Date
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \VisitPlace.dayTimeline)
    var places: [VisitPlace] = []

    @Relationship(deleteRule: .cascade, inverse: \MoveSegment.dayTimeline)
    var moves: [MoveSegment] = []

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
    @Attribute(.unique) var id: UUID
    var arrivalDate: Date
    var departureDate: Date?
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var userLabel: String?
    var createdAt: Date

    var dayTimeline: DayTimeline?

    @Relationship(inverse: \MoveSegment.startPlace)
    var outgoingMoves: [MoveSegment] = []

    @Relationship(inverse: \MoveSegment.endPlace)
    var incomingMoves: [MoveSegment] = []

    init(
        arrivalDate: Date,
        departureDate: Date?,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        userLabel: String? = nil
    ) {
        self.id = UUID()
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.userLabel = userLabel
        self.createdAt = .now
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayTitle: String {
        if let userLabel, !userLabel.isEmpty {
            return userLabel
        }

        let lat = String(format: "%.5f", latitude)
        let lon = String(format: "%.5f", longitude)
        return "\(lat), \(lon)"
    }
}

@Model
final class MoveSegment {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var dedupeKey: String
    var startDate: Date
    var endDate: Date
    var transportModeRawValue: String
    var distanceMeters: Double
    var stepCount: Int?
    var createdAt: Date

    var startPlace: VisitPlace?
    var endPlace: VisitPlace?
    var dayTimeline: DayTimeline?

    @Relationship(deleteRule: .nullify, inverse: \LocationSample.moveSegment)
    var samples: [LocationSample] = []

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
}

@Model
final class LocationSample {
    @Attribute(.unique) var dedupeKey: String
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    var speed: Double
    var sourceRawValue: String
    var createdAt: Date

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

        let place = VisitPlace(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude,
            horizontalAccuracy: visit.horizontalAccuracy
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
        if let existing = try findMove(byDedupeKey: dedupeKey) {
            move = existing
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

    private func normalizedArrivalDate(for visit: CLVisit) -> Date {
        if visit.arrivalDate == .distantPast {
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

    private static func distanceMeters(from lhs: CLLocationCoordinate2D, to rhs: CLLocationCoordinate2D) -> CLLocationDistance {
        let left = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let right = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return left.distance(from: right)
    }
}
