import XCTest
import CoreLocation
import SwiftData
@testable import Moves

final class MockVisit: CLVisit {
    private let mockedCoordinate: CLLocationCoordinate2D
    private let mockedHorizontalAccuracy: CLLocationAccuracy
    private let mockedArrivalDate: Date
    private let mockedDepartureDate: Date

    init(
        coordinate: CLLocationCoordinate2D,
        horizontalAccuracy: CLLocationAccuracy,
        arrivalDate: Date,
        departureDate: Date
    ) {
        self.mockedCoordinate = coordinate
        self.mockedHorizontalAccuracy = horizontalAccuracy
        self.mockedArrivalDate = arrivalDate
        self.mockedDepartureDate = departureDate
        super.init()
    }

    override var coordinate: CLLocationCoordinate2D { mockedCoordinate }
    override var horizontalAccuracy: CLLocationAccuracy { mockedHorizontalAccuracy }
    override var arrivalDate: Date { mockedArrivalDate }
    override var departureDate: Date { mockedDepartureDate }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class TimelineAssemblerTests: XCTestCase {
    func testLocationSamplesAreDeduplicatedAcrossSourcesForTheSameFix() throws {
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let timestamp = Date(timeIntervalSince1970: 1_710_000_000)
        let location = makeLocation(
            latitude: 52.520008,
            longitude: 13.404954,
            speed: 1.2,
            timestamp: timestamp
        )

        _ = try repository.appendSamples(from: [location], source: .launchBackfill)
        _ = try repository.appendSamples(from: [location], source: .significantChange)

        let samples = try repository.samples(
            from: timestamp.addingTimeInterval(-30),
            to: timestamp.addingTimeInterval(30)
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.source, .significantChange)
    }

    func testNearbyLocationSamplesWithinTheDedupWindowCollapseToOneRecord() throws {
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let firstLocation = makeLocation(
            latitude: 52.520008,
            longitude: 13.404954,
            speed: 1.0,
            timestamp: start
        )
        let secondLocation = makeLocation(
            latitude: 52.520215,
            longitude: 13.405115,
            speed: 1.1,
            timestamp: start.addingTimeInterval(45)
        )

        _ = try repository.appendSamples(from: [firstLocation], source: .authorizationGrant)
        _ = try repository.appendSamples(from: [secondLocation], source: .significantChange)

        let samples = try repository.samples(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(120)
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.source, .significantChange)
    }

    func testRouteTrackingSamplesOverrideWeakerSourcesWhenTheyDeduplicate() throws {
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let timestamp = Date(timeIntervalSince1970: 1_710_000_000)
        let location = makeLocation(
            latitude: 52.520008,
            longitude: 13.404954,
            speed: 1.2,
            timestamp: timestamp
        )

        _ = try repository.appendSamples(from: [location], source: .significantChange)
        _ = try repository.appendSamples(from: [location], source: .routeTracking)

        let samples = try repository.samples(
            from: timestamp.addingTimeInterval(-30),
            to: timestamp.addingTimeInterval(30)
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.source, .routeTracking)
    }

    func testRouteDisplayPrefersRouteTrackingSamplesWhenAvailable() {
        let timestamp = Date(timeIntervalSince1970: 1_710_000_000)
        let significantChangeLocation = makeLocation(
            latitude: 52.520008,
            longitude: 13.404954,
            speed: 1.0,
            timestamp: timestamp
        )
        let routeTrackingLocation = makeLocation(
            latitude: 52.521008,
            longitude: 13.405954,
            speed: 1.1,
            timestamp: timestamp.addingTimeInterval(15)
        )

        let samples = [
            LocationSample(location: significantChangeLocation, source: .significantChange, dedupeKey: "a"),
            LocationSample(location: routeTrackingLocation, source: .routeTracking, dedupeKey: "b"),
        ]

        XCTAssertEqual(samples.preferredRouteDisplaySamples.count, 1)
        XCTAssertEqual(samples.preferredRouteDisplaySamples.first?.source, .routeTracking)
    }

    func testMoveSegmentFlagsHighAccuracyRoutesWhenRouteTrackingSamplesArePresent() {
        let startDate = Date(timeIntervalSince1970: 1_710_000_000)
        let endDate = startDate.addingTimeInterval(900)
        let segment = MoveSegment(
            dedupeKey: "move-1",
            startDate: startDate,
            endDate: endDate,
            transportMode: .cycling,
            distanceMeters: 1_200,
            stepCount: 800
        )

        segment.samples = [
            LocationSample(
                location: makeLocation(
                    latitude: 52.520008,
                    longitude: 13.404954,
                    speed: 1.0,
                    timestamp: startDate.addingTimeInterval(120)
                ),
                source: .significantChange,
                dedupeKey: "sig"
            ),
            LocationSample(
                location: makeLocation(
                    latitude: 52.521008,
                    longitude: 13.405954,
                    speed: 2.0,
                    timestamp: startDate.addingTimeInterval(240)
                ),
                source: .routeTracking,
                dedupeKey: "route"
            ),
        ]

        XCTAssertTrue(segment.usesHighAccuracyRouteTracking)

        segment.samples = segment.samples.filter { $0.source != .routeTracking }

        XCTAssertFalse(segment.usesHighAccuracyRouteTracking)
    }

    func testMoveSegmentRouteCacheRoundTripsAndHonorsSignatureChanges() {
        let segment = MoveSegment(
            dedupeKey: "move-cache",
            startDate: Date(timeIntervalSince1970: 1_710_000_000),
            endDate: Date(timeIntervalSince1970: 1_710_000_900),
            transportMode: .walking,
            distanceMeters: 1200,
            stepCount: 1400
        )
        let signature = "signature-1"
        let coordinates = [
            CLLocationCoordinate2D(latitude: 52.520008, longitude: 13.404954),
            CLLocationCoordinate2D(latitude: 52.521008, longitude: 13.405954),
        ]

        XCTAssertNil(segment.cachedRouteCoordinates(for: signature))

        segment.storeCachedRouteCoordinates(coordinates, signature: signature)

        let cached = segment.cachedRouteCoordinates(for: signature)
        XCTAssertEqual(cached?.count, 2)
        XCTAssertEqual(cached?.first?.latitude, coordinates.first?.latitude)
        XCTAssertEqual(cached?.first?.longitude, coordinates.first?.longitude)
        XCTAssertEqual(cached?.last?.latitude, coordinates.last?.latitude)
        XCTAssertEqual(cached?.last?.longitude, coordinates.last?.longitude)
        XCTAssertNil(segment.cachedRouteCoordinates(for: "signature-2"))

        segment.clearCachedRouteCoordinates()
        XCTAssertNil(segment.cachedRouteCoordinates(for: signature))
    }

    func testPlaneArcBendsAboveShadowInNorthernHemisphere() {
        let start = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.3790)
        let end = CLLocationCoordinate2D(latitude: 40.6413, longitude: -73.7781)
        let shadowMidLatitude = (start.latitude + end.latitude) / 2

        let arc = PlaneRouteGeometry.arcCoordinates(from: [start, end])
        XCTAssertGreaterThan(arc.count, 2)

        guard let arcMidPoint = arc[safe: arc.count / 2] else {
            XCTFail("Expected a midpoint in the generated arc")
            return
        }

        XCTAssertGreaterThan(arcMidPoint.latitude, shadowMidLatitude)
    }

    func testPlaneArcBendsBelowShadowInSouthernHemisphere() {
        let start = CLLocationCoordinate2D(latitude: -33.9399, longitude: 151.1753)
        let end = CLLocationCoordinate2D(latitude: -37.6733, longitude: 144.8430)
        let shadowMidLatitude = (start.latitude + end.latitude) / 2

        let arc = PlaneRouteGeometry.arcCoordinates(from: [start, end])
        XCTAssertGreaterThan(arc.count, 2)

        guard let arcMidPoint = arc[safe: arc.count / 2] else {
            XCTFail("Expected a midpoint in the generated arc")
            return
        }

        XCTAssertLessThan(arcMidPoint.latitude, shadowMidLatitude)
    }

    func testMoveRouteCacheSignatureIsStableForTheSameCoordinates() {
        let segment = MoveSegment(
            dedupeKey: "move-signature",
            startDate: Date(timeIntervalSince1970: 1_710_000_000),
            endDate: Date(timeIntervalSince1970: 1_710_000_900),
            transportMode: .walking,
            distanceMeters: 1200,
            stepCount: 1400
        )
        let fallback = [
            CLLocationCoordinate2D(latitude: 52.520008, longitude: 13.404954),
            CLLocationCoordinate2D(latitude: 52.521008, longitude: 13.405954),
        ]

        let first = MoveRouteGeometry.cacheSignature(for: segment, fallback: fallback)
        let second = MoveRouteGeometry.cacheSignature(for: segment, fallback: fallback)

        XCTAssertEqual(first, second)

        let changedFallback = [
            CLLocationCoordinate2D(latitude: 52.520008, longitude: 13.404954),
            CLLocationCoordinate2D(latitude: 52.522008, longitude: 13.406954),
        ]

        XCTAssertNotEqual(first, MoveRouteGeometry.cacheSignature(for: segment, fallback: changedFallback))
    }

    func testTemporaryRouteTrackingEndOfDayFallsBackToTheStartOfTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let start = Date(timeIntervalSince1970: 1_710_000_000)
        guard let expectedEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) else {
            XCTFail("Expected a valid end-of-day boundary")
            return
        }

        XCTAssertEqual(
            TemporaryRouteTrackingDuration.endOfDay.endDate(from: start, calendar: calendar),
            expectedEnd
        )
    }

    func testMoveUpsertIsIdempotentForSameEndpointsAndTimeWindow() throws {
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let startDate = Date(timeIntervalSince1970: 1_710_000_000)
        let endDate = startDate.addingTimeInterval(900)

        let startPlace = VisitPlace(
            arrivalDate: startDate.addingTimeInterval(-300),
            departureDate: startDate,
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 25
        )
        let endPlace = VisitPlace(
            arrivalDate: endDate,
            departureDate: nil,
            latitude: 52.5300,
            longitude: 13.4100,
            horizontalAccuracy: 25
        )

        let sampleLocation = makeLocation(
            latitude: 52.5250,
            longitude: 13.4075,
            speed: 4.0,
            timestamp: startDate.addingTimeInterval(450)
        )
        let samples = try repository.appendSamples(from: [sampleLocation], source: .significantChange)

        _ = try repository.upsertMove(
            startPlace: startPlace,
            endPlace: endPlace,
            startDate: startDate,
            endDate: endDate,
            transportMode: .cycling,
            distanceMeters: 1200,
            stepCount: 1400,
            samples: samples
        )

        _ = try repository.upsertMove(
            startPlace: startPlace,
            endPlace: endPlace,
            startDate: startDate,
            endDate: endDate,
            transportMode: .cycling,
            distanceMeters: 1200,
            stepCount: 1400,
            samples: samples
        )

        let verificationContext = ModelContext(container)
        let descriptor = FetchDescriptor<MoveSegment>()
        let moves = try verificationContext.fetch(descriptor)

        XCTAssertEqual(moves.count, 1)
    }

    func testClassifierFallsBackToSpeedWhenMotionDataIsUnavailable() async {
        let classifier = CoreMotionTransportClassifier()

        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let end = start.addingTimeInterval(180)

        let locations = [
            makeLocation(latitude: 52.5200, longitude: 13.4050, speed: 12.5, timestamp: start),
            makeLocation(latitude: 52.5250, longitude: 13.4100, speed: 14.0, timestamp: start.addingTimeInterval(90)),
            makeLocation(latitude: 52.5300, longitude: 13.4150, speed: 13.5, timestamp: end),
        ]

        let mode = await classifier.classifyTransport(start: start, end: end, locations: locations)
        XCTAssertEqual(mode, .automotive)
    }

    func testClassifierInfersTrainFromHigherSustainedSpeed() async {
        let classifier = CoreMotionTransportClassifier()

        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let end = start.addingTimeInterval(900)

        let locations = [
            makeLocation(latitude: 52.5200, longitude: 13.4050, speed: 24.0, timestamp: start),
            makeLocation(latitude: 52.6200, longitude: 13.5050, speed: 31.0, timestamp: start.addingTimeInterval(450)),
            makeLocation(latitude: 52.7200, longitude: 13.6050, speed: 29.0, timestamp: end),
        ]

        let mode = await classifier.classifyTransport(start: start, end: end, locations: locations)
        XCTAssertEqual(mode, .train)
    }

    func testClassifierInfersPlaneFromVeryHighSpeed() async {
        let classifier = CoreMotionTransportClassifier()

        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let end = start.addingTimeInterval(1_800)

        let locations = [
            makeLocation(latitude: 48.3538, longitude: 11.7861, speed: 85.0, timestamp: start),
            makeLocation(latitude: 50.1109, longitude: 8.6821, speed: 92.0, timestamp: start.addingTimeInterval(900)),
            makeLocation(latitude: 52.3086, longitude: 4.7639, speed: 95.0, timestamp: end),
        ]

        let mode = await classifier.classifyTransport(start: start, end: end, locations: locations)
        XCTAssertEqual(mode, .plane)
    }

    func testClassifierDoesNotMarkLongDistanceAsStationaryWhenSpeedIsZero() async {
        let classifier = CoreMotionTransportClassifier()

        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let end = start.addingTimeInterval(5_400)

        let locations = [
            makeLocation(latitude: 52.5200, longitude: 13.4050, speed: 0, timestamp: start),
            makeLocation(latitude: 52.5550, longitude: 13.4600, speed: 0, timestamp: start.addingTimeInterval(2_700)),
            makeLocation(latitude: 52.5900, longitude: 13.5150, speed: 0, timestamp: end),
        ]

        let mode = await classifier.classifyTransport(start: start, end: end, locations: locations)
        XCTAssertNotEqual(mode, .stationary)
    }

    func testMoveUpsertUpdatesExistingSegmentForSamePlacePairWhenWindowChanges() throws {
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let arrival = Date(timeIntervalSince1970: 1_710_000_000)
        let correctedStart = arrival.addingTimeInterval(4 * 60 * 60)
        let endDate = correctedStart.addingTimeInterval(5 * 60)

        let startPlace = VisitPlace(
            arrivalDate: arrival,
            departureDate: correctedStart,
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 25
        )
        let endPlace = VisitPlace(
            arrivalDate: endDate,
            departureDate: nil,
            latitude: 52.5300,
            longitude: 13.4100,
            horizontalAccuracy: 25
        )

        let sample = makeLocation(
            latitude: 52.5250,
            longitude: 13.4075,
            speed: 4.5,
            timestamp: correctedStart.addingTimeInterval(150)
        )
        let samples = try repository.appendSamples(from: [sample], source: .significantChange)

        _ = try repository.upsertMove(
            startPlace: startPlace,
            endPlace: endPlace,
            startDate: arrival,
            endDate: endDate,
            transportMode: .cycling,
            distanceMeters: 1_250,
            stepCount: 700,
            samples: samples
        )

        _ = try repository.upsertMove(
            startPlace: startPlace,
            endPlace: endPlace,
            startDate: correctedStart,
            endDate: endDate,
            transportMode: .cycling,
            distanceMeters: 1_250,
            stepCount: 700,
            samples: samples
        )

        let verificationContext = ModelContext(container)
        let descriptor = FetchDescriptor<MoveSegment>()
        let moves = try verificationContext.fetch(descriptor)

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.startDate, correctedStart)
    }

    func testDayTimelineCountsRepeatedVisitsToTheSameLocationOnce() {
        let dayTimeline = DayTimeline(dayStart: Date(timeIntervalSince1970: 1_710_000_000))

        let firstHomeVisit = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_710_000_000),
            departureDate: Date(timeIntervalSince1970: 1_710_000_900),
            latitude: 52.52001,
            longitude: 13.40501,
            horizontalAccuracy: 20
        )
        let cafeVisit = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_710_001_800),
            departureDate: Date(timeIntervalSince1970: 1_710_002_100),
            latitude: 52.53000,
            longitude: 13.41500,
            horizontalAccuracy: 20
        )
        let secondHomeVisit = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_710_002_400),
            departureDate: nil,
            latitude: 52.52004,
            longitude: 13.40504,
            horizontalAccuracy: 20
        )

        dayTimeline.places = [firstHomeVisit, cafeVisit, secondHomeVisit]

        XCTAssertEqual(dayTimeline.uniqueLocationCount, 2)
    }

    func testAddOrUpdateVisitDeduplicatesNearlyIdenticalVisits() throws {
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let baseArrival = Date(timeIntervalSince1970: 1_710_000_000)
        let baseDeparture = baseArrival.addingTimeInterval(15 * 60)

        let firstVisit = MockVisit(
            coordinate: CLLocationCoordinate2D(latitude: 52.520008, longitude: 13.404954),
            horizontalAccuracy: 20,
            arrivalDate: baseArrival,
            departureDate: baseDeparture
        )
        let secondVisit = MockVisit(
            coordinate: CLLocationCoordinate2D(latitude: 52.520245, longitude: 13.405111),
            horizontalAccuracy: 18,
            arrivalDate: baseArrival.addingTimeInterval(150),
            departureDate: baseDeparture.addingTimeInterval(150)
        )

        let firstPlace = try repository.addOrUpdateVisit(from: firstVisit)
        let secondPlace = try repository.addOrUpdateVisit(from: secondVisit)

        XCTAssertEqual(firstPlace.id, secondPlace.id)

        let verificationContext = ModelContext(container)
        let places = try verificationContext.fetch(FetchDescriptor<VisitPlace>())
        XCTAssertEqual(places.count, 1)
    }

    func testHistoricalDeduplicationKeepsLongerDuplicateStayWithoutMoveContext() throws {
        let container = try makeInMemoryContainer()
        let seedContext = ModelContext(container)

        let dayStart = Date(timeIntervalSince1970: 1_710_000_000)
        let timeline = DayTimeline(dayStart: dayStart)
        seedContext.insert(timeline)

        let arrival = dayStart.addingTimeInterval(2 * 60 * 60)
        let shortDeparture = arrival.addingTimeInterval(6 * 60)
        let longDeparture = arrival.addingTimeInterval(9 * 60)

        let shortStay = VisitPlace(
            arrivalDate: arrival,
            departureDate: shortDeparture,
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 20
        )
        shortStay.dayTimeline = timeline

        let longStay = VisitPlace(
            arrivalDate: arrival.addingTimeInterval(15),
            departureDate: longDeparture,
            latitude: 52.5201,
            longitude: 13.4051,
            horizontalAccuracy: 18
        )
        longStay.dayTimeline = timeline

        seedContext.insert(shortStay)
        seedContext.insert(longStay)
        try seedContext.save()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let report = try repository.runHistoricalDeduplication()

        let verificationContext = ModelContext(container)
        let places = try verificationContext.fetch(FetchDescriptor<VisitPlace>())

        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.id, longStay.id)
        XCTAssertEqual(places.first?.departureDate, longDeparture)
        XCTAssertGreaterThanOrEqual(report.removedPlaceCount, 1)
    }

    func testHistoricalDeduplicationKeepsDuplicateStayThatFitsSurroundingMoves() throws {
        let container = try makeInMemoryContainer()
        let seedContext = ModelContext(container)

        let dayStart = Date(timeIntervalSince1970: 1_710_000_000)
        let timeline = DayTimeline(dayStart: dayStart)
        seedContext.insert(timeline)

        let arrival = dayStart.addingTimeInterval(2 * 60 * 60)
        let shortDeparture = arrival.addingTimeInterval(6 * 60)
        let longDeparture = arrival.addingTimeInterval(9 * 60)

        let previousPlace = VisitPlace(
            arrivalDate: arrival.addingTimeInterval(-30 * 60),
            departureDate: arrival.addingTimeInterval(-20 * 60),
            latitude: 52.5100,
            longitude: 13.3950,
            horizontalAccuracy: 25
        )
        previousPlace.dayTimeline = timeline

        let shortStay = VisitPlace(
            arrivalDate: arrival,
            departureDate: shortDeparture,
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 18
        )
        shortStay.dayTimeline = timeline

        let longStay = VisitPlace(
            arrivalDate: arrival.addingTimeInterval(20),
            departureDate: longDeparture,
            latitude: 52.5201,
            longitude: 13.4051,
            horizontalAccuracy: 18
        )
        longStay.dayTimeline = timeline

        let nextPlace = VisitPlace(
            arrivalDate: shortDeparture.addingTimeInterval(12 * 60),
            departureDate: nil,
            latitude: 52.5350,
            longitude: 13.4200,
            horizontalAccuracy: 25
        )
        nextPlace.dayTimeline = timeline

        seedContext.insert(previousPlace)
        seedContext.insert(shortStay)
        seedContext.insert(longStay)
        seedContext.insert(nextPlace)

        let incomingMove = MoveSegment(
            dedupeKey: "incoming-fit",
            startDate: arrival.addingTimeInterval(-20 * 60),
            endDate: arrival,
            transportMode: .walking,
            distanceMeters: 1_300,
            stepCount: 1_600
        )
        incomingMove.startPlace = previousPlace
        incomingMove.endPlace = shortStay
        incomingMove.dayTimeline = timeline

        let outgoingMove = MoveSegment(
            dedupeKey: "outgoing-fit",
            startDate: shortDeparture,
            endDate: shortDeparture.addingTimeInterval(12 * 60),
            transportMode: .walking,
            distanceMeters: 1_350,
            stepCount: 1_650
        )
        outgoingMove.startPlace = shortStay
        outgoingMove.endPlace = nextPlace
        outgoingMove.dayTimeline = timeline

        seedContext.insert(incomingMove)
        seedContext.insert(outgoingMove)
        try seedContext.save()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let report = try repository.runHistoricalDeduplication()

        let verificationContext = ModelContext(container)
        let places = try verificationContext.fetch(FetchDescriptor<VisitPlace>())
        let moves = try verificationContext.fetch(FetchDescriptor<MoveSegment>())

        XCTAssertEqual(places.count, 3)
        XCTAssertGreaterThanOrEqual(report.removedPlaceCount, 1)

        let remainingIDs = Set(places.map(\.id))
        XCTAssertTrue(remainingIDs.contains(shortStay.id))
        XCTAssertFalse(remainingIDs.contains(longStay.id))

        let retainedStay = places.first { $0.id == shortStay.id }
        XCTAssertEqual(retainedStay?.departureDate, shortDeparture)

        XCTAssertEqual(moves.count, 2)
        XCTAssertTrue(moves.contains(where: { $0.endPlace?.id == shortStay.id }))
        XCTAssertTrue(moves.contains(where: { $0.startPlace?.id == shortStay.id }))
    }

    func testUpsertMoveDeduplicatesSimilarMovesAcrossEquivalentEndpoints() throws {
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let startDate = Date(timeIntervalSince1970: 1_710_000_000)
        let endDate = startDate.addingTimeInterval(18 * 60)

        let firstStartPlace = VisitPlace(
            arrivalDate: startDate.addingTimeInterval(-8 * 60),
            departureDate: startDate,
            latitude: 52.520000,
            longitude: 13.405000,
            horizontalAccuracy: 25
        )
        let firstEndPlace = VisitPlace(
            arrivalDate: endDate,
            departureDate: nil,
            latitude: 52.580000,
            longitude: 13.470000,
            horizontalAccuracy: 25
        )

        let secondStartPlace = VisitPlace(
            arrivalDate: startDate.addingTimeInterval(-7 * 60),
            departureDate: startDate.addingTimeInterval(25),
            latitude: 52.520260,
            longitude: 13.405220,
            horizontalAccuracy: 20
        )
        let secondEndPlace = VisitPlace(
            arrivalDate: endDate.addingTimeInterval(25),
            departureDate: nil,
            latitude: 52.580240,
            longitude: 13.470180,
            horizontalAccuracy: 20
        )

        let sampleOne = makeLocation(
            latitude: 52.548000,
            longitude: 13.438000,
            speed: 11.0,
            timestamp: startDate.addingTimeInterval(8 * 60)
        )
        let sampleTwo = makeLocation(
            latitude: 52.549100,
            longitude: 13.439300,
            speed: 11.5,
            timestamp: startDate.addingTimeInterval(9 * 60)
        )

        let firstSamples = try repository.appendSamples(from: [sampleOne], source: .significantChange)
        let secondSamples = try repository.appendSamples(from: [sampleTwo], source: .routeTracking)

        _ = try repository.upsertMove(
            startPlace: firstStartPlace,
            endPlace: firstEndPlace,
            startDate: startDate,
            endDate: endDate,
            transportMode: .automotive,
            distanceMeters: 10_200,
            stepCount: nil,
            samples: firstSamples
        )

        _ = try repository.upsertMove(
            startPlace: secondStartPlace,
            endPlace: secondEndPlace,
            startDate: startDate.addingTimeInterval(20),
            endDate: endDate.addingTimeInterval(20),
            transportMode: .automotive,
            distanceMeters: 10_260,
            stepCount: nil,
            samples: secondSamples
        )

        let verificationContext = ModelContext(container)
        let moves = try verificationContext.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(moves.count, 1)
    }

    func testHistoricalDeduplicationSweepMergesExistingDuplicatePlacesAndMoves() throws {
        let container = try makeInMemoryContainer()
        let seedContext = ModelContext(container)

        let dayStart = Date(timeIntervalSince1970: 1_710_000_000)
        let timeline = DayTimeline(dayStart: dayStart)
        seedContext.insert(timeline)

        let startOne = VisitPlace(
            arrivalDate: dayStart.addingTimeInterval(30 * 60),
            departureDate: dayStart.addingTimeInterval(36 * 60),
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 20
        )
        startOne.dayTimeline = timeline

        let startTwo = VisitPlace(
            arrivalDate: dayStart.addingTimeInterval(31 * 60),
            departureDate: dayStart.addingTimeInterval(37 * 60),
            latitude: 52.5203,
            longitude: 13.4052,
            horizontalAccuracy: 18
        )
        startTwo.dayTimeline = timeline

        let endOne = VisitPlace(
            arrivalDate: dayStart.addingTimeInterval(54 * 60),
            departureDate: nil,
            latitude: 52.5800,
            longitude: 13.4700,
            horizontalAccuracy: 20
        )
        endOne.dayTimeline = timeline

        let endTwo = VisitPlace(
            arrivalDate: dayStart.addingTimeInterval(55 * 60),
            departureDate: nil,
            latitude: 52.5802,
            longitude: 13.4702,
            horizontalAccuracy: 18
        )
        endTwo.dayTimeline = timeline

        seedContext.insert(startOne)
        seedContext.insert(startTwo)
        seedContext.insert(endOne)
        seedContext.insert(endTwo)

        let moveOne = MoveSegment(
            dedupeKey: "legacy-1",
            startDate: dayStart.addingTimeInterval(36 * 60),
            endDate: dayStart.addingTimeInterval(54 * 60),
            transportMode: .automotive,
            distanceMeters: 10_200,
            stepCount: nil
        )
        moveOne.startPlace = startOne
        moveOne.endPlace = endOne
        moveOne.dayTimeline = timeline

        let moveTwo = MoveSegment(
            dedupeKey: "legacy-2",
            startDate: dayStart.addingTimeInterval(36 * 60 + 40),
            endDate: dayStart.addingTimeInterval(54 * 60 + 40),
            transportMode: .automotive,
            distanceMeters: 10_260,
            stepCount: nil
        )
        moveTwo.startPlace = startTwo
        moveTwo.endPlace = endTwo
        moveTwo.dayTimeline = timeline

        seedContext.insert(moveOne)
        seedContext.insert(moveTwo)
        try seedContext.save()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let report = try repository.runHistoricalDeduplication()

        let verificationContext = ModelContext(container)
        let places = try verificationContext.fetch(FetchDescriptor<VisitPlace>())
        let moves = try verificationContext.fetch(FetchDescriptor<MoveSegment>())

        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(moves.count, 1)
        XCTAssertGreaterThanOrEqual(report.removedPlaceCount, 2)
        XCTAssertGreaterThanOrEqual(report.removedMoveCount, 1)
    }

    func testUndoSnapshotRestoresPreviousTimelineState() throws {
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)

        let startDate = Date(timeIntervalSince1970: 1_710_000_000)
        let endDate = startDate.addingTimeInterval(15 * 60)
        let startPlace = VisitPlace(
            arrivalDate: startDate.addingTimeInterval(-4 * 60),
            departureDate: startDate,
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 20
        )
        let endPlace = VisitPlace(
            arrivalDate: endDate,
            departureDate: nil,
            latitude: 52.5300,
            longitude: 13.4120,
            horizontalAccuracy: 20
        )

        let sampleLocation = makeLocation(
            latitude: 52.5250,
            longitude: 13.4080,
            speed: 4.0,
            timestamp: startDate.addingTimeInterval(8 * 60)
        )
        let samples = try repository.appendSamples(from: [sampleLocation], source: .significantChange)
        _ = try repository.upsertMove(
            startPlace: startPlace,
            endPlace: endPlace,
            startDate: startDate,
            endDate: endDate,
            transportMode: .cycling,
            distanceMeters: 1_500,
            stepCount: 1_800,
            samples: samples
        )

        let snapshot = try repository.createUndoSnapshot()

        let mutationContext = ModelContext(container)
        let allMoves = try mutationContext.fetch(FetchDescriptor<MoveSegment>())
        allMoves.forEach(mutationContext.delete)
        try mutationContext.save()

        try repository.restoreFromUndoSnapshot(snapshot)

        let verificationContext = ModelContext(container)
        let restoredMoves = try verificationContext.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(restoredMoves.count, 1)
        XCTAssertEqual(restoredMoves.first?.transportMode, .cycling)
    }

    func testDeleteMoveUndoRegistrationRestoresMoveSnapshot() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let undoManager = UndoManager()

        let startDate = Date(timeIntervalSince1970: 1_710_000_000)
        let endDate = startDate.addingTimeInterval(15 * 60)

        let timeline = DayTimeline(dayStart: startDate)
        context.insert(timeline)

        let startPlace = VisitPlace(
            arrivalDate: startDate.addingTimeInterval(-5 * 60),
            departureDate: startDate,
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 20
        )
        startPlace.dayTimeline = timeline
        context.insert(startPlace)

        let endPlace = VisitPlace(
            arrivalDate: endDate,
            departureDate: nil,
            latitude: 52.5300,
            longitude: 13.4120,
            horizontalAccuracy: 20
        )
        endPlace.dayTimeline = timeline
        context.insert(endPlace)

        let move = MoveSegment(
            dedupeKey: "undo-delete-move",
            startDate: startDate,
            endDate: endDate,
            transportMode: .walking,
            distanceMeters: 1_200,
            stepCount: 1_500
        )
        move.startPlace = startPlace
        move.endPlace = endPlace
        move.dayTimeline = timeline
        context.insert(move)
        try context.save()

        let payload = (
            id: move.id,
            dedupeKey: move.dedupeKey,
            startDate: move.startDate,
            endDate: move.endDate,
            transportMode: move.transportMode,
            distanceMeters: move.distanceMeters,
            stepCount: move.stepCount,
            createdAt: move.createdAt,
            startPlace: move.startPlace,
            endPlace: move.endPlace,
            dayTimeline: move.dayTimeline,
            routeCacheSignature: move.routeCacheSignature,
            routeCacheCoordinatesData: move.routeCacheCoordinatesData,
            samples: move.samples
        )

        context.delete(move)
        try context.save()

        undoManager.registerUndo(withTarget: context) { context in
            let restored = MoveSegment(
                dedupeKey: payload.dedupeKey,
                startDate: payload.startDate,
                endDate: payload.endDate,
                transportMode: payload.transportMode,
                distanceMeters: payload.distanceMeters,
                stepCount: payload.stepCount
            )
            restored.id = payload.id
            restored.createdAt = payload.createdAt
            restored.startPlace = payload.startPlace
            restored.endPlace = payload.endPlace
            restored.dayTimeline = payload.dayTimeline
            restored.routeCacheSignature = payload.routeCacheSignature
            restored.routeCacheCoordinatesData = payload.routeCacheCoordinatesData
            context.insert(restored)

            for sample in payload.samples {
                sample.moveSegment = restored
            }
        }

        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        if context.hasChanges {
            try context.save()
        }

        let restoredMoves = try context.fetch(FetchDescriptor<MoveSegment>())
        XCTAssertEqual(restoredMoves.count, 1)
        XCTAssertEqual(restoredMoves.first?.dedupeKey, "undo-delete-move")
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            MoveSegment.self,
            LocationSample.self,
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )

        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }

    private func makeLocation(
        latitude: CLLocationDegrees,
        longitude: CLLocationDegrees,
        speed: CLLocationSpeed,
        timestamp: Date
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 20,
            verticalAccuracy: 20,
            course: 0,
            speed: speed,
            timestamp: timestamp
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
