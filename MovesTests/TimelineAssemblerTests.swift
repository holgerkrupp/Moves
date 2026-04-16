import XCTest
import CoreLocation
import SwiftData
@testable import Moves

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
