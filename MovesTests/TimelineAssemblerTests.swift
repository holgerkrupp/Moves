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

final class MovesTimelinePeriodTests: XCTestCase {
    func testTodayUsesCalendarDayBoundaries() throws {
        let calendar = testCalendar
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 10,
            hour: 14,
            minute: 30
        )))
        let interval = try XCTUnwrap(
            MovesTimelinePeriod.today.dateInterval(containing: now, calendar: calendar)
        )

        XCTAssertEqual(calendar.component(.day, from: interval.start), 10)
        XCTAssertEqual(calendar.component(.hour, from: interval.start), 0)
        XCTAssertEqual(calendar.component(.day, from: interval.end), 11)
    }

    func testLastSevenDaysIncludesTodayAndSixPreviousDays() throws {
        let calendar = testCalendar
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 10,
            hour: 14
        )))
        let interval = try XCTUnwrap(
            MovesTimelinePeriod.lastSevenDays.dateInterval(containing: now, calendar: calendar)
        )

        XCTAssertEqual(calendar.dateComponents([.day], from: interval.start, to: interval.end).day, 7)
        XCTAssertTrue(interval.contains(now))
    }

    func testAllTimeHasNoDateLimit() {
        XCTAssertNil(MovesTimelinePeriod.allTime.dateInterval())
    }

    private var testCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
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

    func testHealthWorkoutRouteGeometryKeepsCloseSpacedPoints() {
        let startDate = Date(timeIntervalSince1970: 1_710_000_000)
        let segment = MoveSegment(
            dedupeKey: "health-route-detail",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30),
            transportMode: .walking,
            distanceMeters: 4,
            stepCount: nil
        )

        segment.samples = [
            LocationSample(
                location: makeLocation(
                    latitude: 52.520000,
                    longitude: 13.405000,
                    speed: 1,
                    timestamp: startDate
                ),
                source: .healthWorkoutRoute,
                dedupeKey: "health-1"
            ),
            LocationSample(
                location: makeLocation(
                    latitude: 52.520018,
                    longitude: 13.405000,
                    speed: 1,
                    timestamp: startDate.addingTimeInterval(10)
                ),
                source: .healthWorkoutRoute,
                dedupeKey: "health-2"
            ),
            LocationSample(
                location: makeLocation(
                    latitude: 52.520036,
                    longitude: 13.405000,
                    speed: 1,
                    timestamp: startDate.addingTimeInterval(20)
                ),
                source: .healthWorkoutRoute,
                dedupeKey: "health-3"
            ),
        ]
        segment.startPlace = VisitPlace(
            arrivalDate: startDate,
            departureDate: startDate,
            latitude: 52.519000,
            longitude: 13.404000,
            horizontalAccuracy: 20
        )
        segment.endPlace = VisitPlace(
            arrivalDate: startDate.addingTimeInterval(30),
            departureDate: nil,
            latitude: 52.521000,
            longitude: 13.406000,
            horizontalAccuracy: 20
        )

        XCTAssertTrue(segment.usesHealthWorkoutRoute)
        let coordinates = MoveRouteGeometry.rawCoordinates(for: segment)
        XCTAssertEqual(coordinates.count, 3)
        XCTAssertEqual(coordinates.first?.latitude, 52.520000)
        XCTAssertEqual(coordinates.last?.latitude, 52.520036)
    }

    func testHealthWorkoutRouteImportPreservesDenseRouteSamples() throws {
        let container = try makeInMemoryContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let startDate = Date(timeIntervalSince1970: 1_710_000_000)
        let routeLocations = [
            makeLocation(
                latitude: 52.520000,
                longitude: 13.405000,
                speed: 1,
                timestamp: startDate
            ),
            makeLocation(
                latitude: 52.520018,
                longitude: 13.405000,
                speed: 1,
                timestamp: startDate.addingTimeInterval(10)
            ),
            makeLocation(
                latitude: 52.520036,
                longitude: 13.405000,
                speed: 1,
                timestamp: startDate.addingTimeInterval(20)
            ),
        ]

        let move = try repository.importRouteTrack(
            locations: routeLocations,
            source: .healthWorkoutRoute,
            transportMode: .walking
        )

        XCTAssertNotNil(move)
        guard let move else { return }
        XCTAssertEqual(move.samples.count, 3)
        XCTAssertEqual(MoveRouteGeometry.rawCoordinates(for: move).count, 3)
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

    func testMatchedRouteSynchronizesMoveDistanceWithDisplayedCoordinates() async {
        let displayedCoordinates = [
            CLLocationCoordinate2D(latitude: 53.481587, longitude: 9.695481),
            CLLocationCoordinate2D(latitude: 53.482779, longitude: 9.684570),
            CLLocationCoordinate2D(latitude: 53.480376, longitude: 9.687597),
        ]
        let segment = MoveSegment(
            dedupeKey: "displayed-route-distance",
            startDate: Date(timeIntervalSince1970: 1_789_195_419),
            endDate: Date(timeIntervalSince1970: 1_789_195_547),
            transportMode: .automotive,
            distanceMeters: 539,
            stepCount: nil
        )
        segment.storeManualRouteCoordinates(displayedCoordinates)

        let matchedCoordinates = await RoadRouteMatcher.matchedCoordinates(for: segment)

        XCTAssertEqual(matchedCoordinates.count, displayedCoordinates.count)
        XCTAssertEqual(
            segment.distanceMeters,
            routeDistance(for: matchedCoordinates),
            accuracy: 0.01
        )
        XCTAssertEqual(segment.distanceMeters, 1_071, accuracy: 1)
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

    func testRoadRouteAnchorsKeepIntermediatePointsForShortRoutes() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 52.520000, longitude: 13.405000),
            CLLocationCoordinate2D(latitude: 52.521000, longitude: 13.406000),
            CLLocationCoordinate2D(latitude: 52.522000, longitude: 13.407000),
            CLLocationCoordinate2D(latitude: 52.523000, longitude: 13.408000),
            CLLocationCoordinate2D(latitude: 52.524000, longitude: 13.409000),
        ]

        let anchors = RoadRouteMatcher.routeAnchors(for: coordinates, transportMode: .automotive)

        XCTAssertEqual(anchors.first?.latitude, coordinates.first?.latitude)
        XCTAssertEqual(anchors.last?.latitude, coordinates.last?.latitude)
        XCTAssertTrue(
            anchors.dropFirst().dropLast().contains { anchor in
                coordinates.dropFirst().dropLast().contains { coordinate in
                    anchor.latitude == coordinate.latitude && anchor.longitude == coordinate.longitude
                }
            },
            "Expected route matching anchors to include intermediate route points."
        )
    }

    func testRouteMatchRejectsAStreetRouteThatIsMuchLongerThanTheRecordedTrack() {
        let recorded = [
            CLLocationCoordinate2D(latitude: 48.1000, longitude: 11.5000),
            CLLocationCoordinate2D(latitude: 48.1100, longitude: 11.5000),
            CLLocationCoordinate2D(latitude: 48.1200, longitude: 11.5000),
        ]
        let detour = [
            CLLocationCoordinate2D(latitude: 48.1000, longitude: 11.5000),
            CLLocationCoordinate2D(latitude: 48.1000, longitude: 11.5500),
            CLLocationCoordinate2D(latitude: 48.1200, longitude: 11.5500),
            CLLocationCoordinate2D(latitude: 48.1200, longitude: 11.5000),
        ]

        XCTAssertFalse(
            RouteMatchPlausibility.isAcceptable(
                detour,
                comparedTo: recorded,
                transportMode: .automotive
            )
        )
    }

    func testRouteMatchRejectsAHighwayRouteFarFromRecordedIntermediatePoints() {
        let recorded = [
            CLLocationCoordinate2D(latitude: 48.1000, longitude: 11.5000),
            CLLocationCoordinate2D(latitude: 48.1500, longitude: 11.5000),
            CLLocationCoordinate2D(latitude: 48.1000, longitude: 11.6000),
        ]
        let endpointRoute = [
            CLLocationCoordinate2D(latitude: 48.1000, longitude: 11.5000),
            CLLocationCoordinate2D(latitude: 48.1000, longitude: 11.6000),
        ]

        XCTAssertFalse(
            RouteMatchPlausibility.isAcceptable(
                endpointRoute,
                comparedTo: recorded,
                transportMode: .automotive
            )
        )
    }

    func testRouteMatchAcceptsAStreetRouteCloseToRecordedPoints() {
        let recorded = [
            CLLocationCoordinate2D(latitude: 48.1000, longitude: 11.5000),
            CLLocationCoordinate2D(latitude: 48.1100, longitude: 11.5100),
            CLLocationCoordinate2D(latitude: 48.1200, longitude: 11.5200),
        ]
        let matched = [
            CLLocationCoordinate2D(latitude: 48.1000, longitude: 11.5000),
            CLLocationCoordinate2D(latitude: 48.1105, longitude: 11.5105),
            CLLocationCoordinate2D(latitude: 48.1200, longitude: 11.5200),
        ]

        XCTAssertTrue(
            RouteMatchPlausibility.isAcceptable(
                matched,
                comparedTo: recorded,
                transportMode: .automotive
            )
        )
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

    func testHistoricalDeduplicationRepairsMissingStayBetweenIncomingAndOutgoingMove() throws {
        let container = try makeInMemoryContainer()
        let seedContext = ModelContext(container)

        let dayStart = Date(timeIntervalSince1970: 1_710_000_000)
        let timeline = DayTimeline(dayStart: dayStart)
        seedContext.insert(timeline)

        let incomingEnd = dayStart.addingTimeInterval(9 * 60 * 60)
        let outgoingStart = incomingEnd.addingTimeInterval(62 * 60)
        let outgoingEnd = outgoingStart.addingTimeInterval(20 * 60)

        let previousPlace = VisitPlace(
            arrivalDate: incomingEnd.addingTimeInterval(-40 * 60),
            departureDate: incomingEnd.addingTimeInterval(-30 * 60),
            latitude: 52.5000,
            longitude: 13.3900,
            horizontalAccuracy: 25
        )
        previousPlace.dayTimeline = timeline

        let origin = VisitPlace(
            arrivalDate: outgoingStart,
            departureDate: outgoingStart,
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 18
        )
        origin.dayTimeline = timeline

        let home = VisitPlace(
            arrivalDate: outgoingEnd,
            departureDate: nil,
            latitude: 52.5400,
            longitude: 13.4250,
            horizontalAccuracy: 18
        )
        home.dayTimeline = timeline

        let nearHome = VisitPlace(
            arrivalDate: outgoingEnd.addingTimeInterval(20),
            departureDate: outgoingEnd.addingTimeInterval(2 * 60),
            latitude: 52.5415,
            longitude: 13.4270,
            horizontalAccuracy: 20
        )
        nearHome.dayTimeline = timeline

        seedContext.insert(previousPlace)
        seedContext.insert(origin)
        seedContext.insert(home)
        seedContext.insert(nearHome)

        let incomingMove = MoveSegment(
            dedupeKey: "incoming-gap",
            startDate: incomingEnd.addingTimeInterval(-30 * 60),
            endDate: incomingEnd,
            transportMode: .automotive,
            distanceMeters: 6_200,
            stepCount: nil
        )
        incomingMove.startPlace = previousPlace
        incomingMove.endPlace = origin
        incomingMove.dayTimeline = timeline

        let moveToHome = MoveSegment(
            dedupeKey: "out-home",
            startDate: outgoingStart,
            endDate: outgoingEnd,
            transportMode: .automotive,
            distanceMeters: 7_300,
            stepCount: nil
        )
        moveToHome.startPlace = origin
        moveToHome.endPlace = home
        moveToHome.dayTimeline = timeline

        let moveToNearHome = MoveSegment(
            dedupeKey: "out-near-home",
            startDate: outgoingStart.addingTimeInterval(15),
            endDate: outgoingEnd.addingTimeInterval(15),
            transportMode: .automotive,
            distanceMeters: 7_340,
            stepCount: nil
        )
        moveToNearHome.startPlace = origin
        moveToNearHome.endPlace = nearHome
        moveToNearHome.dayTimeline = timeline

        seedContext.insert(incomingMove)
        seedContext.insert(moveToHome)
        seedContext.insert(moveToNearHome)
        try seedContext.save()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        _ = try repository.runHistoricalDeduplication()

        let verificationContext = ModelContext(container)
        let moves = try verificationContext.fetch(FetchDescriptor<MoveSegment>())
        let allPlaces = try verificationContext.fetch(FetchDescriptor<VisitPlace>())
        let repairedOrigin = try XCTUnwrap(allPlaces.first(where: { $0.id == origin.id }))

        XCTAssertEqual(moves.count, 2)
        XCTAssertTrue(moves.contains(where: { $0.endPlace?.id == home.id }))
        XCTAssertFalse(moves.contains(where: { $0.endPlace?.id == nearHome.id }))
        XCTAssertEqual(repairedOrigin.arrivalDate, incomingEnd)
        XCTAssertEqual(repairedOrigin.departureDate, outgoingStart)
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

    func testSharePeriodsUseCalendarBoundariesWithoutIncludingTheNextPeriod() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2

        let selectedDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 10,
            hour: 12
        ))!

        for period in [MovesSharePeriod.day, .week, .month, .year] {
            let interval = try XCTUnwrap(period.dateInterval(containing: selectedDate, calendar: calendar))
            let lastMoment = interval.end.addingTimeInterval(-1)

            XCTAssertTrue(
                period.contains(lastMoment, periodStart: selectedDate, calendar: calendar),
                "\(period.rawValue) should include its last moment"
            )
            XCTAssertFalse(
                period.contains(interval.end, periodStart: selectedDate, calendar: calendar),
                "\(period.rawValue) must not include the first moment of the next period"
            )
        }

        XCTAssertTrue(
            MovesSharePeriod.forever.contains(
                .distantFuture,
                periodStart: selectedDate,
                calendar: calendar
            )
        )
    }

    func testShareGPXFilenamesFollowTheSelectedPeriod() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2

        let selectedDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 10,
            hour: 12
        ))!

        XCTAssertEqual(
            MovesSharePeriod.day.gpxFileStem(for: selectedDate, calendar: calendar),
            "moves-2026-09-10"
        )
        XCTAssertEqual(
            MovesSharePeriod.week.gpxFileStem(for: selectedDate, calendar: calendar),
            "moves-week-2026-09-07"
        )
        XCTAssertEqual(
            MovesSharePeriod.month.gpxFileStem(for: selectedDate, calendar: calendar),
            "moves-2026-09"
        )
        XCTAssertEqual(
            MovesSharePeriod.year.gpxFileStem(for: selectedDate, calendar: calendar),
            "moves-2026"
        )
        XCTAssertEqual(
            MovesSharePeriod.forever.gpxFileStem(for: selectedDate, calendar: calendar),
            "moves-all-days"
        )
    }

    func testShareHeatIntensityChangesGraduallyWithFrequency() {
        let once = MovesShareHeatScale.intensity(frequency: 1, maximum: 100)
        let twice = MovesShareHeatScale.intensity(frequency: 2, maximum: 100)
        let fourTimes = MovesShareHeatScale.intensity(frequency: 4, maximum: 100)
        let sixteenTimes = MovesShareHeatScale.intensity(frequency: 16, maximum: 100)
        let maximum = MovesShareHeatScale.intensity(frequency: 100, maximum: 100)

        XCTAssertEqual(once, 0)
        XCTAssertGreaterThan(twice, once)
        XCTAssertGreaterThan(fourTimes, twice)
        XCTAssertGreaterThan(sixteenTimes, fourTimes)
        XCTAssertGreaterThan(maximum, sixteenTimes)
        XCTAssertLessThanOrEqual(maximum, 1)

        // A low-frequency route must not become fully hot just because it is the
        // most-used route in a short selected period.
        XCTAssertLessThan(MovesShareHeatScale.intensity(frequency: 2, maximum: 2), 0.5)
    }

    func testSharePeriodsChooseDirectOrAggregatedTrackRendering() {
        XCTAssertTrue(MovesSharePeriod.day.includesAllTracks)
        XCTAssertTrue(MovesSharePeriod.week.includesAllTracks)
        XCTAssertTrue(MovesSharePeriod.month.includesAllTracks)
        XCTAssertTrue(MovesSharePeriod.year.includesAllTracks)
        XCTAssertFalse(MovesSharePeriod.forever.includesAllTracks)

        XCTAssertTrue(MovesSharePeriod.day.buildsTracksDirectly)
        XCTAssertTrue(MovesSharePeriod.week.buildsTracksDirectly)
        XCTAssertTrue(MovesSharePeriod.month.buildsTracksDirectly)
        XCTAssertFalse(MovesSharePeriod.year.buildsTracksDirectly)
        XCTAssertFalse(MovesSharePeriod.forever.buildsTracksDirectly)
    }

    func testShareCalendarIsOnlyAvailableForMonths() {
        XCTAssertFalse(MovesSharePeriod.day.includesCalendar)
        XCTAssertFalse(MovesSharePeriod.week.includesCalendar)
        XCTAssertTrue(MovesSharePeriod.month.includesCalendar)
        XCTAssertFalse(MovesSharePeriod.year.includesCalendar)
        XCTAssertFalse(MovesSharePeriod.forever.includesCalendar)
    }

    func testShareMapAggregateRoundTripsThroughSwiftData() throws {
        let schema = Schema([ShareMapAggregate.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let periodStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let tracks = [
            ShareMapAggregateTrack(
                id: UUID(),
                transportMode: .cycling,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 53.55, longitude: 9.99),
                    CLLocationCoordinate2D(latitude: 53.56, longitude: 10.01)
                ]
            )
        ]
        let key = try XCTUnwrap(
            ShareMapAggregateStore.periodKey(for: .year, date: periodStart)
        )
        context.insert(ShareMapAggregate(
            periodKey: key,
            period: .year,
            periodStart: periodStart,
            sourceSignature: ShareMapAggregateStore.sourceSignature(for: []),
            tracksData: try ShareMapAggregateStore.encodeTracks(tracks)
        ))
        try context.save()

        let restored = try XCTUnwrap(ShareMapAggregateStore.cachedTracks(
            for: .year,
            periodStart: periodStart,
            timelines: [],
            in: context
        ))
        XCTAssertEqual(restored.count, 1)
        let restoredTrack = try XCTUnwrap(restored.first)
        XCTAssertEqual(restoredTrack.transportMode, .cycling)
        XCTAssertEqual(restoredTrack.coordinates.count, 2)
        XCTAssertEqual(restoredTrack.coordinates.first?.latitude ?? 0, 53.55, accuracy: 0.000_001)
    }

    func testVisitedPlaceEntityIndexesUsefulMetadataWithoutPrivateCoordinatesOrComments() {
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let timeline = DayTimeline(dayStart: arrival)
        let place = VisitPlace(
            arrivalDate: arrival,
            departureDate: arrival.addingTimeInterval(45 * 60),
            latitude: 52.5200,
            longitude: 13.4050,
            horizontalAccuracy: 15,
            userLabel: "Favorite Café",
            autoLabel: "Coffee Shop",
            comment: "Private meeting notes"
        )
        place.dayTimeline = timeline

        let entity = VisitedPlaceEntity(place: place)
        let attributes = entity.attributeSet

        XCTAssertEqual(entity.id, place.id.uuidString)
        XCTAssertEqual(entity.name, "Favorite Café")
        XCTAssertEqual(entity.dayKey, timeline.dayKey)
        XCTAssertEqual(attributes.displayName, "Favorite Café")
        XCTAssertNil(attributes.latitude)
        XCTAssertNil(attributes.longitude)
        XCTAssertFalse(attributes.contentDescription?.contains("Private meeting notes") ?? true)
        XCTAssertFalse(attributes.contentDescription?.contains("52.52") ?? true)
    }

    func testMultiDeviceResolverUsesMovingPhoneWhenCompanionIsStationary() {
        let samples = multiDeviceSamples(
            device: "moving",
            coordinates: [(52.5200, 13.4050), (52.5220, 13.4050), (52.5240, 13.4050)]
        ) + multiDeviceSamples(
            device: "home",
            coordinates: [(52.5000, 13.4000), (52.5001, 13.4000), (52.5000, 13.4001)]
        )

        let resolution = MultiDeviceTimelineResolver.resolve(
            samples: samples,
            preferredDeviceIdentifier: "home"
        )

        XCTAssertEqual(resolution.kind, .singleJourney)
        XCTAssertEqual(resolution.visibleDeviceIdentifier, "moving")
        XCTAssertTrue(resolution.includes("moving"))
        XCTAssertFalse(resolution.includes("home"))
    }

    func testMultiDeviceResolverSilentlyMergesCoTravellingPhones() {
        let samples = multiDeviceSamples(
            device: "phone-a",
            coordinates: [(52.5200, 13.4050), (52.5220, 13.4050), (52.5240, 13.4050)]
        ) + multiDeviceSamples(
            device: "phone-b",
            coordinates: [(52.5201, 13.4051), (52.5221, 13.4051), (52.5241, 13.4051)]
        )

        let resolution = MultiDeviceTimelineResolver.resolve(
            samples: samples,
            preferredDeviceIdentifier: "phone-b"
        )

        XCTAssertEqual(resolution.kind, .coTravelling)
        XCTAssertEqual(resolution.visibleDeviceIdentifier, "phone-a")
        XCTAssertTrue(resolution.includes("phone-a"))
        XCTAssertFalse(resolution.includes("phone-b"))
    }

    func testMultiDeviceResolverSeparatesIndependentMovingPhones() {
        let samples = multiDeviceSamples(
            device: "owner",
            coordinates: [(52.5200, 13.4050), (52.5220, 13.4050), (52.5240, 13.4050)]
        ) + multiDeviceSamples(
            device: "loaner",
            coordinates: [(52.4200, 13.1050), (52.4220, 13.1050), (52.4240, 13.1050)]
        )

        let resolution = MultiDeviceTimelineResolver.resolve(
            samples: samples,
            preferredDeviceIdentifier: "owner"
        )

        XCTAssertEqual(resolution.kind, .independentJourneys)
        XCTAssertEqual(resolution.visibleDeviceIdentifier, "owner")
        XCTAssertEqual(resolution.otherMovingDeviceIdentifiers, ["loaner"])
        XCTAssertTrue(resolution.includes("owner"))
        XCTAssertFalse(resolution.includes("loaner"))
    }

    func testRepositoryKeepsNewSamplesScopedToCapturingPhone() throws {
        let container = try makeInMemoryContainer()
        let phoneA = SwiftDataTimelineRepository(modelContainer: container, deviceIdentifier: "phone-a")
        let phoneB = SwiftDataTimelineRepository(modelContainer: container, deviceIdentifier: "phone-b")
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000)

        _ = try phoneA.appendSamples(
            from: [makeLocation(latitude: 52.52, longitude: 13.405, speed: 3, timestamp: timestamp)],
            source: .routeTracking
        )
        _ = try phoneB.appendSamples(
            from: [makeLocation(latitude: 52.42, longitude: 13.105, speed: 3, timestamp: timestamp)],
            source: .routeTracking
        )

        let phoneASamples = try phoneA.samples(
            from: timestamp.addingTimeInterval(-1),
            to: timestamp.addingTimeInterval(1)
        )
        let phoneBSamples = try phoneB.samples(
            from: timestamp.addingTimeInterval(-1),
            to: timestamp.addingTimeInterval(1)
        )

        XCTAssertEqual(phoneASamples.map(\.deviceIdentifier), ["phone-a"])
        XCTAssertEqual(phoneBSamples.map(\.deviceIdentifier), ["phone-b"])
    }

    private func multiDeviceSamples(
        device: String,
        coordinates: [(CLLocationDegrees, CLLocationDegrees)]
    ) -> [LocationSample] {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return coordinates.enumerated().map { index, coordinate in
            LocationSample(
                location: makeLocation(
                    latitude: coordinate.0,
                    longitude: coordinate.1,
                    speed: 4,
                    timestamp: start.addingTimeInterval(TimeInterval(index * 5 * 60))
                ),
                source: .routeTracking,
                dedupeKey: "\(device)-\(index)",
                deviceIdentifier: device
            )
        }
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            KnownLocation.self,
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
