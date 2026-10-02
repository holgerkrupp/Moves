import CoreLocation
import Foundation

/// The identifier used by flight matching is deliberately independent of any
/// provider's identifiers. A Move's UUID is stable for the lifetime of the
/// record and is enough to associate a result with the local Move.
typealias StableMoveID = UUID

struct FlightCoordinate: Codable, Equatable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(to other: FlightCoordinate) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

/// A bounded, Sendable projection of a flight Move. It intentionally contains
/// no SwiftData objects and can therefore cross an actor/network boundary.
struct FlightFingerprint: Codable, Equatable, Sendable {
    let moveID: StableMoveID
    let start: Date
    let end: Date
    let startCoordinate: FlightCoordinate?
    let endCoordinate: FlightCoordinate?
    let sampledRoute: [FlightCoordinate]
    let distanceMeters: Double?
    let originCountry: String?
    let destinationCountry: String?

    init(
        moveID: StableMoveID,
        start: Date,
        end: Date,
        startCoordinate: FlightCoordinate?,
        endCoordinate: FlightCoordinate?,
        sampledRoute: [FlightCoordinate],
        distanceMeters: Double?,
        originCountry: String? = nil,
        destinationCountry: String? = nil
    ) {
        self.moveID = moveID
        self.start = start
        self.end = max(end, start)
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.sampledRoute = Self.boundedRoute(sampledRoute)
        self.distanceMeters = distanceMeters.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.originCountry = originCountry
        self.destinationCountry = destinationCountry
    }

    init(move: MoveSegment, route: [CLLocationCoordinate2D]? = nil, maxRoutePoints: Int = 24) {
        let rawRoute = route ?? MoveRouteGeometry.rawCoordinates(for: move)
        let boundedRoute = Self.boundedRoute(rawRoute.map(FlightCoordinate.init), maxCount: maxRoutePoints)
        self.init(
            moveID: move.id,
            start: move.timelineStartDate,
            end: move.endDate,
            startCoordinate: move.startPlace.map { FlightCoordinate($0.coordinate) } ?? boundedRoute.first,
            endCoordinate: move.endPlace.map { FlightCoordinate($0.coordinate) } ?? boundedRoute.last,
            sampledRoute: boundedRoute,
            distanceMeters: move.distanceMeters
        )
    }

    private static func boundedRoute(_ coordinates: [FlightCoordinate], maxCount: Int = 24) -> [FlightCoordinate] {
        guard maxCount > 0, coordinates.count > maxCount else { return coordinates }
        guard maxCount > 2 else { return [coordinates.first, coordinates.last].compactMap { $0 } }

        let step = Double(coordinates.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { index in
            coordinates[Int((Double(index) * step).rounded())]
        }
    }

    private static func boundedRoute(_ coordinates: [CLLocationCoordinate2D], maxCount: Int = 24) -> [FlightCoordinate] {
        boundedRoute(coordinates.map(FlightCoordinate.init), maxCount: maxCount)
    }

    var timeInterval: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

enum AirportType: String, Codable, Equatable, Sendable {
    case largeAirport
    case mediumAirport
    case smallAirport
    case heliport
}

struct AirportRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    let icaoCode: String
    let iataCode: String?
    let name: String
    let coordinate: FlightCoordinate
    let municipality: String?
    let countryCode: String?
    let airportType: AirportType

    var id: String { icaoCode }
}

struct AirportCandidate: Codable, Equatable, Hashable, Sendable, Identifiable {
    let airport: AirportRecord
    let distanceMeters: Double

    var id: String { airport.id }
    var icaoCode: String { airport.icaoCode }
    var iataCode: String? { airport.iataCode }
    var coordinate: FlightCoordinate { airport.coordinate }
    var name: String { airport.name }
    var municipality: String? { airport.municipality }
    var countryCode: String? { airport.countryCode }

    init(airport: AirportRecord, distanceMeters: Double) {
        self.airport = airport
        self.distanceMeters = distanceMeters
    }
}

protocol AirportDatabase: Sendable {
    func candidates(near coordinate: FlightCoordinate, within radiusMeters: Double) -> [AirportCandidate]
}

struct StaticAirportDatabase: AirportDatabase, Sendable {
    let records: [AirportRecord]

    init(records: [AirportRecord]) {
        self.records = records
    }

    func candidates(near coordinate: FlightCoordinate, within radiusMeters: Double) -> [AirportCandidate] {
        records.compactMap { airport in
            let distance = airport.coordinate.distance(to: coordinate)
            guard distance <= radiusMeters else { return nil }
            return AirportCandidate(airport: airport, distanceMeters: distance)
        }
        .sorted { lhs, rhs in
            if lhs.distanceMeters != rhs.distanceMeters { return lhs.distanceMeters < rhs.distanceMeters }
            return lhs.icaoCode < rhs.icaoCode
        }
    }
}

/// A deliberately small, versioned starter set. The database is replaceable so
/// a fuller independently licensed airport dataset can be shipped later.
enum BundledAirportDatabase {
    static let version = "starter-1"

    static func make() -> StaticAirportDatabase {
        StaticAirportDatabase(records: [
            airport("EDDH", "HAM", "Hamburg Airport", 53.6304, 9.9882, "Hamburg", "DE"),
            airport("EDDM", "MUC", "Munich Airport", 48.3538, 11.7861, "Munich", "DE"),
            airport("EDDB", "BER", "Berlin Brandenburg Airport", 52.3667, 13.5033, "Berlin", "DE"),
            airport("EDDF", "FRA", "Frankfurt Airport", 50.0379, 8.5622, "Frankfurt", "DE"),
            airport("EGLL", "LHR", "London Heathrow Airport", 51.4700, -0.4543, "London", "GB"),
            airport("LFPG", "CDG", "Paris Charles de Gaulle Airport", 49.0097, 2.5479, "Paris", "FR"),
            airport("KJFK", "JFK", "John F. Kennedy International Airport", 40.6413, -73.7781, "New York", "US"),
            airport("KSFO", "SFO", "San Francisco International Airport", 37.6213, -122.3790, "San Francisco", "US"),
            airport("RJTT", "HND", "Tokyo Haneda Airport", 35.5494, 139.7798, "Tokyo", "JP"),
            airport("RKSI", "ICN", "Incheon International Airport", 37.4602, 126.4407, "Incheon", "KR"),
            airport("YSSY", "SYD", "Sydney Airport", -33.9399, 151.1753, "Sydney", "AU"),
            airport("YMML", "MEL", "Melbourne Airport", -37.6733, 144.8430, "Melbourne", "AU"),
        ])
    }

    private static func airport(
        _ icao: String,
        _ iata: String,
        _ name: String,
        _ latitude: Double,
        _ longitude: Double,
        _ municipality: String,
        _ countryCode: String
    ) -> AirportRecord {
        AirportRecord(
            icaoCode: icao,
            iataCode: iata,
            name: name,
            coordinate: FlightCoordinate(latitude: latitude, longitude: longitude),
            municipality: municipality,
            countryCode: countryCode,
            airportType: .largeAirport
        )
    }
}

struct FlightAirportResolution: Codable, Equatable, Sendable {
    let originCandidates: [AirportCandidate]
    let destinationCandidates: [AirportCandidate]
}

enum FlightAirportResolver {
    static let defaultRadiusMeters = 150_000.0
    static let maximumCandidates = 4

    static func resolve(
        fingerprint: FlightFingerprint,
        database: AirportDatabase,
        radiusMeters: Double = defaultRadiusMeters
    ) -> FlightAirportResolution {
        func resolveEndpoint(_ coordinate: FlightCoordinate?, routeIndex: Int) -> [AirportCandidate] {
            guard let coordinate else { return [] }
            let endpointCandidates = database.candidates(near: coordinate, within: radiusMeters)
            guard !endpointCandidates.isEmpty else { return [] }

            // GPS capture commonly starts after the terminal or shortly after
            // takeoff. Let the first/last useful route points corroborate the
            // endpoint without ever forcing the nearest airport into a match.
            let routePoint = fingerprint.sampledRoute.indices.contains(routeIndex) ? fingerprint.sampledRoute[routeIndex] : nil
            return endpointCandidates
                .map { candidate in
                    let routeDistance = routePoint.map { candidate.coordinate.distance(to: $0) } ?? candidate.distanceMeters
                    return (candidate: candidate, distance: min(candidate.distanceMeters, routeDistance))
                }
                .sorted { lhs, rhs in
                    if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                    return lhs.candidate.icaoCode < rhs.candidate.icaoCode
                }
                .prefix(maximumCandidates)
                .map { $0.candidate }
        }

        return FlightAirportResolution(
            originCandidates: resolveEndpoint(fingerprint.startCoordinate, routeIndex: 0),
            destinationCandidates: resolveEndpoint(fingerprint.endCoordinate, routeIndex: max(fingerprint.sampledRoute.count - 1, 0))
        )
    }
}

struct HistoricalFlightCandidate: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let airlineName: String?
    let airlineIATA: String?
    let airlineICAO: String?
    let marketedFlightNumber: String?
    let callsign: String?
    let origin: AirportCandidate
    let destination: AirportCandidate
    let scheduledDeparture: Date?
    let actualDeparture: Date?
    let scheduledArrival: Date?
    let actualArrival: Date?
    let aircraftRegistration: String?
    let aircraftType: String?
    let historicalTrack: [FlightCoordinate]
    let routeDistanceMeters: Double?
    let sourceIdentifier: String

    var departure: Date? { actualDeparture ?? scheduledDeparture }
    var arrival: Date? { actualArrival ?? scheduledArrival }
    var duration: TimeInterval? {
        guard let departure, let arrival else { return nil }
        return max(0, arrival.timeIntervalSince(departure))
    }

    var displayFlightNumber: String {
        if let marketedFlightNumber, !marketedFlightNumber.isEmpty { return marketedFlightNumber }
        return callsign ?? "Unknown flight"
    }
}

enum HistoricalFlightProviderError: Error, Equatable {
    case unavailable
    case invalidRequest
}

protocol HistoricalFlightProvider: Sendable {
    func flights(
        origin: AirportCandidate,
        destination: AirportCandidate,
        around: DateInterval
    ) async throws -> [HistoricalFlightCandidate]
}

struct UnavailableHistoricalFlightProvider: HistoricalFlightProvider {
    func flights(origin: AirportCandidate, destination: AirportCandidate, around: DateInterval) async throws -> [HistoricalFlightCandidate] {
        throw HistoricalFlightProviderError.unavailable
    }
}

struct InMemoryHistoricalFlightProvider: HistoricalFlightProvider {
    let candidates: [HistoricalFlightCandidate]

    func flights(origin: AirportCandidate, destination: AirportCandidate, around: DateInterval) async throws -> [HistoricalFlightCandidate] {
        candidates.filter { candidate in
            candidate.origin.icaoCode == origin.icaoCode &&
            candidate.destination.icaoCode == destination.icaoCode &&
            [candidate.departure, candidate.arrival].compactMap { $0 }.contains { around.contains($0) }
        }
    }
}

enum FlightMatchEvidenceSignal: String, Codable, Equatable, Sendable {
    case originAirport
    case destinationAirport
    case departureTime
    case arrivalTime
    case duration
    case distance
    case trajectory
    case country
}

struct FlightMatchEvidence: Codable, Equatable, Sendable {
    let signal: FlightMatchEvidenceSignal
    let contribution: Double
    let detail: String
}

struct FlightMatch: Codable, Equatable, Sendable, Identifiable {
    let candidate: HistoricalFlightCandidate
    let score: Double
    let confidence: Double
    let evidence: [FlightMatchEvidence]

    var id: String { candidate.id }
}

enum FlightMatchRanker {
    static let minimumUsefulScore = 0.45

    static func isUseful(_ match: FlightMatch, for fingerprint: FlightFingerprint) -> Bool {
        guard match.score >= minimumUsefulScore else { return false }
        guard !fingerprint.sampledRoute.isEmpty, !match.candidate.historicalTrack.isEmpty else { return true }

        // A provider track that is hundreds of kilometres away is stronger
        // negative evidence than a matching callsign is positive evidence.
        let averageDistance = fingerprint.sampledRoute.reduce(0.0) { partial, point in
            partial + (match.candidate.historicalTrack.map { point.distance(to: $0) }.min() ?? 0)
        } / Double(fingerprint.sampledRoute.count)
        return averageDistance <= 250_000
    }

    static func rank(
        fingerprint: FlightFingerprint,
        candidate: HistoricalFlightCandidate
    ) -> FlightMatch {
        var evidence: [FlightMatchEvidence] = []
        var total = 0.0
        var activeWeight = 0.0

        func add(_ signal: FlightMatchEvidenceSignal, weight: Double, value: Double, detail: String) {
            activeWeight += weight
            let contribution = max(0, min(1, value)) * weight
            total += contribution
            evidence.append(FlightMatchEvidence(signal: signal, contribution: contribution, detail: detail))
        }

        add(.originAirport, weight: 0.20, value: airportScore(candidate.origin.distanceMeters), detail: "Origin " + formattedDistance(candidate.origin.distanceMeters) + " from recorded endpoint")
        add(.destinationAirport, weight: 0.20, value: airportScore(candidate.destination.distanceMeters), detail: "Destination " + formattedDistance(candidate.destination.distanceMeters) + " from recorded endpoint")

        if let departure = candidate.departure {
            add(.departureTime, weight: 0.20, value: timeScore(abs(departure.timeIntervalSince(fingerprint.start))), detail: "Departure " + formattedDelta(departure.timeIntervalSince(fingerprint.start)) + " from recording")
        }
        if let arrival = candidate.arrival {
            add(.arrivalTime, weight: 0.20, value: timeScore(abs(arrival.timeIntervalSince(fingerprint.end))), detail: "Arrival " + formattedDelta(arrival.timeIntervalSince(fingerprint.end)) + " from recording")
        }
        if let duration = candidate.duration {
            add(.duration, weight: 0.10, value: durationScore(abs(duration - fingerprint.timeInterval)), detail: "Duration differs by " + formattedDelta(duration - fingerprint.timeInterval))
        }
        if let routeDistance = candidate.routeDistanceMeters, let recordedDistance = fingerprint.distanceMeters {
            add(.distance, weight: 0.05, value: relativeScore(routeDistance, recordedDistance, tolerance: 0.45), detail: "Route distance " + formattedDistance(abs(routeDistance - recordedDistance)) + " different")
        }
        if let trackDistance = trajectoryDistance(fingerprint.sampledRoute, candidate.historicalTrack), !candidate.historicalTrack.isEmpty {
            add(.trajectory, weight: 0.05, value: distanceScore(trackDistance, tolerance: 120_000), detail: "Recorded route is " + formattedDistance(trackDistance) + " from provider track")
        }
        if let originCountry = fingerprint.originCountry, let candidateCountry = candidate.origin.countryCode {
            add(.country, weight: 0.025, value: originCountry.caseInsensitiveCompare(candidateCountry) == .orderedSame ? 1 : 0, detail: "Origin country " + candidateCountry)
        }
        if let destinationCountry = fingerprint.destinationCountry, let candidateCountry = candidate.destination.countryCode {
            add(.country, weight: 0.025, value: destinationCountry.caseInsensitiveCompare(candidateCountry) == .orderedSame ? 1 : 0, detail: "Destination country " + candidateCountry)
        }

        let normalizedScore = activeWeight == 0 ? 0 : total / activeWeight
        return FlightMatch(candidate: candidate, score: normalizedScore, confidence: normalizedScore, evidence: evidence)
    }

    private static func airportScore(_ distance: Double) -> Double {
        distanceScore(distance, tolerance: 45_000)
    }

    private static func timeScore(_ delta: TimeInterval) -> Double {
        exp(-delta / (2 * 3_600))
    }

    private static func durationScore(_ delta: TimeInterval) -> Double {
        exp(-delta / (2 * 1_800))
    }

    private static func distanceScore(_ distance: Double, tolerance: Double) -> Double {
        exp(-max(distance, 0) / tolerance)
    }

    private static func relativeScore(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Double {
        guard max(lhs, rhs) > 0 else { return 0 }
        return max(0, 1 - abs(lhs - rhs) / max(lhs, rhs) / tolerance)
    }

    private static func trajectoryDistance(_ route: [FlightCoordinate], _ track: [FlightCoordinate]) -> Double? {
        guard !route.isEmpty, !track.isEmpty else { return nil }
        let total = route.reduce(0.0) { partial, point in
            partial + (track.map { point.distance(to: $0) }.min() ?? 0)
        }
        return total / Double(route.count)
    }

    private static func formattedDistance(_ meters: Double) -> String {
        Measurement(value: max(meters, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private static func formattedDelta(_ seconds: TimeInterval) -> String {
        let minutes = Int((abs(seconds) / 60).rounded())
        return (seconds < 0 ? "−" : "+") + "\(minutes) min"
    }
}

struct FlightMatchResponse: Codable, Equatable, Sendable {
    let fingerprint: FlightFingerprint
    let airportResolution: FlightAirportResolution
    let matches: [FlightMatch]
    let providerUnavailable: Bool

    var bestMatch: FlightMatch? { matches.first }
    var hasAmbiguity: Bool {
        guard matches.count > 1 else { return false }
        return matches[0].confidence - matches[1].confidence < 0.08
    }
}

/// User-triggered matching pipeline. There is intentionally no call site in
/// ExplorationPreparation: creating this service and calling `match` is the
/// explicit opt-in boundary for network enrichment.
actor FlightMatchingService {
    private let database: AirportDatabase
    private let provider: HistoricalFlightProvider
    private var cache: [String: FlightMatchResponse] = [:]

    init(
        database: AirportDatabase = BundledAirportDatabase.make(),
        provider: HistoricalFlightProvider
    ) {
        self.database = database
        self.provider = provider
    }

    func match(_ fingerprint: FlightFingerprint) async throws -> FlightMatchResponse {
        let cacheKey = Self.cacheKey(for: fingerprint)
        if let cached = cache[cacheKey] { return cached }

        let resolution = FlightAirportResolver.resolve(fingerprint: fingerprint, database: database)
        guard !resolution.originCandidates.isEmpty, !resolution.destinationCandidates.isEmpty else {
            let response = FlightMatchResponse(fingerprint: fingerprint, airportResolution: resolution, matches: [], providerUnavailable: false)
            cache[cacheKey] = response
            return response
        }

        let interval = DateInterval(
            start: fingerprint.start.addingTimeInterval(-12 * 3_600),
            end: fingerprint.end.addingTimeInterval(12 * 3_600)
        )
        var candidates: [HistoricalFlightCandidate] = []
        var providerUnavailable = false

        for origin in resolution.originCandidates {
            for destination in resolution.destinationCandidates {
                do {
                    candidates += try await provider.flights(origin: origin, destination: destination, around: interval)
                } catch {
                    providerUnavailable = true
                }
            }
        }

        var unique: [String: HistoricalFlightCandidate] = [:]
        for candidate in candidates { unique[candidate.id] = candidate }
        let ranked = unique.values
            .map { FlightMatchRanker.rank(fingerprint: fingerprint, candidate: $0) }
            .filter { FlightMatchRanker.isUseful($0, for: fingerprint) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.candidate.id < $1.candidate.id
            }

        let response = FlightMatchResponse(
            fingerprint: fingerprint,
            airportResolution: resolution,
            matches: ranked,
            providerUnavailable: providerUnavailable
        )
        cache[cacheKey] = response
        return response
    }

    private static func cacheKey(for fingerprint: FlightFingerprint) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = (try? encoder.encode(fingerprint)) ?? Data()
        return data.base64EncodedString()
    }
}

enum FlightMetadataProvenance: String, Codable, CaseIterable, Sendable {
    case providerSuggested
    case userConfirmed
    case userEntered
    case imported
}

struct FlightMetadata: Codable, Equatable, Sendable {
    let airlineName: String?
    let airlineIATA: String?
    let airlineICAO: String?
    let marketedFlightNumber: String?
    let callsign: String?
    let originIATA: String?
    let originICAO: String?
    let destinationIATA: String?
    let destinationICAO: String?
    let scheduledDeparture: Date?
    let actualDeparture: Date?
    let scheduledArrival: Date?
    let actualArrival: Date?
    let aircraftRegistration: String?
    let aircraftType: String?
    let providerSourceIdentifier: String?
    let provenance: FlightMetadataProvenance
    let recordedAt: Date
    var isStale: Bool

    init(
        airlineName: String?,
        airlineIATA: String? = nil,
        airlineICAO: String? = nil,
        marketedFlightNumber: String?,
        callsign: String? = nil,
        originIATA: String?,
        originICAO: String? = nil,
        destinationIATA: String?,
        destinationICAO: String? = nil,
        scheduledDeparture: Date? = nil,
        actualDeparture: Date? = nil,
        scheduledArrival: Date? = nil,
        actualArrival: Date? = nil,
        aircraftRegistration: String? = nil,
        aircraftType: String? = nil,
        providerSourceIdentifier: String? = nil,
        provenance: FlightMetadataProvenance,
        recordedAt: Date = .now,
        isStale: Bool = false
    ) {
        self.airlineName = airlineName
        self.airlineIATA = airlineIATA
        self.airlineICAO = airlineICAO
        self.marketedFlightNumber = marketedFlightNumber
        self.callsign = callsign
        self.originIATA = originIATA
        self.originICAO = originICAO
        self.destinationIATA = destinationIATA
        self.destinationICAO = destinationICAO
        self.scheduledDeparture = scheduledDeparture
        self.actualDeparture = actualDeparture
        self.scheduledArrival = scheduledArrival
        self.actualArrival = actualArrival
        self.aircraftRegistration = aircraftRegistration
        self.aircraftType = aircraftType
        self.providerSourceIdentifier = providerSourceIdentifier
        self.provenance = provenance
        self.recordedAt = recordedAt
        self.isStale = isStale
    }

    init(match: FlightMatch, provenance: FlightMetadataProvenance, recordedAt: Date = .now) {
        let candidate = match.candidate
        self.init(
            airlineName: candidate.airlineName,
            airlineIATA: candidate.airlineIATA,
            airlineICAO: candidate.airlineICAO,
            marketedFlightNumber: candidate.marketedFlightNumber,
            callsign: candidate.callsign,
            originIATA: candidate.origin.iataCode,
            originICAO: candidate.origin.icaoCode,
            destinationIATA: candidate.destination.iataCode,
            destinationICAO: candidate.destination.icaoCode,
            scheduledDeparture: candidate.scheduledDeparture,
            actualDeparture: candidate.actualDeparture,
            scheduledArrival: candidate.scheduledArrival,
            actualArrival: candidate.actualArrival,
            aircraftRegistration: candidate.aircraftRegistration,
            aircraftType: candidate.aircraftType,
            providerSourceIdentifier: candidate.sourceIdentifier,
            provenance: provenance,
            recordedAt: recordedAt
        )
    }

    var displayName: String {
        [airlineName, marketedFlightNumber].compactMap { $0 }.joined(separator: " ")
    }
}

extension MoveSegment {
    private static let flightMetadataEncoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    var flightMetadata: FlightMetadata? {
        get {
            guard let data = flightMetadataData else { return nil }
            return try? PropertyListDecoder().decode(FlightMetadata.self, from: data)
        }
        set {
            flightMetadataData = newValue.flatMap { try? Self.flightMetadataEncoder.encode($0) }
        }
    }

    var hasAuthoritativeFlightMetadata: Bool {
        guard let provenance = flightMetadata?.provenance else { return false }
        return provenance == .userConfirmed || provenance == .userEntered || provenance == .imported
    }

    @discardableResult
    func storeProviderSuggestion(_ match: FlightMatch) -> Bool {
        guard transportMode == .plane else { return false }
        if let current = flightMetadata,
           current.provenance == .userConfirmed || current.provenance == .userEntered || current.provenance == .imported {
            return false
        }
        flightMetadata = FlightMetadata(match: match, provenance: .providerSuggested)
        return true
    }

    @discardableResult
    func confirmFlightMatch(_ match: FlightMatch) -> Bool {
        guard transportMode == .plane else { return false }
        if let current = flightMetadata,
           current.provenance == .userEntered || current.provenance == .imported {
            return false
        }
        flightMetadata = FlightMetadata(match: match, provenance: .userConfirmed)
        return true
    }

    @discardableResult
    func setUserEnteredFlightMetadata(_ metadata: FlightMetadata) -> Bool {
        guard metadata.provenance == .userEntered || metadata.provenance == .imported else { return false }
        flightMetadata = metadata
        return true
    }

    @discardableResult
    func rejectProviderSuggestion() -> Bool {
        guard flightMetadata?.provenance == .providerSuggested else { return false }
        flightMetadata = nil
        return true
    }

    func markFlightMatchStale() {
        guard var metadata = flightMetadata, metadata.provenance == .providerSuggested else { return }
        metadata.isStale = true
        flightMetadata = metadata
    }
}
