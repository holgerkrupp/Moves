import XCTest
import CoreLocation
import SwiftData
@testable import Moves

final class MovesStatisticsSearchTests: XCTestCase {
    func testElevationProfileSortsFiltersDeduplicatesSplitsAndDownsamples() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            DayElevationSample(timestamp: start.addingTimeInterval(10 * 60), elevationMeters: 120),
            DayElevationSample(timestamp: start.addingTimeInterval(5 * 60), elevationMeters: 100),
            DayElevationSample(timestamp: start.addingTimeInterval(5 * 60 + 0.5), elevationMeters: 110),
            DayElevationSample(timestamp: start.addingTimeInterval(30 * 60), elevationMeters: 130),
            DayElevationSample(timestamp: start.addingTimeInterval(3_600), elevationMeters: 400),
            DayElevationSample(timestamp: start.addingTimeInterval(3_660), elevationMeters: .nan),
            DayElevationSample(timestamp: start.addingTimeInterval(4_000), elevationMeters: 140),
            DayElevationSample(timestamp: start.addingTimeInterval(24 * 60 * 60), elevationMeters: 900)
        ]

        let profile = try XCTUnwrap(
            DayElevationProfileBuilder.build(
                samples: samples,
                dayStart: start,
                maximumPointCount: 4
            )
        )

        XCTAssertEqual(profile.segments.count, 2)
        XCTAssertEqual(profile.segments.flatMap(\.points).count, 4)
        XCTAssertEqual(profile.segments.first?.points.first?.elevationMeters, 110)
        XCTAssertEqual(profile.maximumElevationMeters, 400)
        XCTAssertEqual(profile.minimumElevationMeters, 110)
    }

    func testStatisticsRecordIndexUsesCompactDailySummaries() {
        let firstDay = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDay = firstDay.addingTimeInterval(24 * 60 * 60)
        let summaries = [
            "first": TimelineDaySummary(
                dayStart: firstDay,
                placeCount: 2,
                uniquePlaceCount: 1,
                moveCount: 1,
                totalDistanceMeters: 2_000,
                maximumElevationMeters: 240,
                longestStayDuration: 3_600
            ),
            "second": TimelineDaySummary(
                dayStart: secondDay,
                placeCount: 1,
                uniquePlaceCount: 1,
                moveCount: 2,
                totalDistanceMeters: 8_000,
                maximumElevationMeters: 320,
                longestStayDuration: 1_800
            )
        ]

        let records = MovesStatisticsRecordIndex(daySummaries: summaries)

        XCTAssertEqual(records.recordedVisitCount, 3)
        XCTAssertEqual(records.recordedPlaceCount, 2)
        XCTAssertEqual(records.recordedMoveCount, 3)
        XCTAssertEqual(records.longestTravelDay?.totalDistanceMeters, 8_000)
        XCTAssertEqual(records.maximumElevation?.maximumElevationMeters, 320)
        XCTAssertEqual(records.longestSingleStay?.longestStayDuration, 3_600)
        XCTAssertEqual(records.activityStreakDays, 2)
    }

    func testStatisticsRecordIndexIgnoresFlightAltitudeRecords() {
        let groundDay = TimelineDaySummary(
            dayStart: Date(timeIntervalSince1970: 1_700_000_000),
            maximumElevationMeters: 320
        )
        let flightDay = TimelineDaySummary(
            dayStart: Date(timeIntervalSince1970: 1_700_000_000 + 24 * 60 * 60),
            maximumElevationMeters: 10_000
        )

        let records = MovesStatisticsRecordIndex(daySummaries: [
            "ground": groundDay,
            "flight": flightDay
        ])

        XCTAssertEqual(records.maximumElevation?.maximumElevationMeters, 320)
        XCTAssertTrue(TimelineElevationRules.isTrustworthy(10_000))
        XCTAssertFalse(TimelineElevationRules.isRecordable(10_000))
    }

    func testTimelineDaySummaryDecodesWithoutNewRecordFields() throws {
        let legacy = LegacyTimelineDaySummaryForTest(dayStart: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(TimelineDaySummary.self, from: data)

        XCTAssertEqual(decoded.dayStart, legacy.dayStart)
        XCTAssertNil(decoded.maximumElevationMeters)
        XCTAssertNil(decoded.longestStayDuration)
    }

    func testKnownLocationUsesItsIndividualRadius() {
        let location = KnownLocation(
            name: "Office",
            latitude: 53.5500,
            longitude: 9.9900,
            radiusMeters: 100
        )

        XCTAssertTrue(location.contains(CLLocationCoordinate2D(latitude: 53.5504, longitude: 9.9900)))
        XCTAssertFalse(location.contains(CLLocationCoordinate2D(latitude: 53.5520, longitude: 9.9900)))

        location.radiusMeters = 300
        XCTAssertTrue(location.contains(CLLocationCoordinate2D(latitude: 53.5520, longitude: 9.9900)))
    }

    func testRegularPlaceReconciliationKeepsManualLabelsSeparate() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let matchingOldLabel = makePlace(title: "Office", arrival: start, departure: nil)
        let matchingCustomLabel = makePlace(title: "Customer Meeting", arrival: start, departure: nil)
        let location = KnownLocation(
            name: "Work",
            latitude: 53.0,
            longitude: 10.0,
            radiusMeters: 150
        )

        KnownLocationLabeler.reconcile(
            location: location,
            replacedID: nil,
            definitions: [location],
            to: [matchingOldLabel, matchingCustomLabel]
        )

        XCTAssertNil(matchingOldLabel.userLabel)
        XCTAssertEqual(matchingOldLabel.regularPlaceName, "Work")
        XCTAssertEqual(matchingCustomLabel.userLabel, "Customer Meeting")
        XCTAssertNil(matchingCustomLabel.regularPlaceName)
    }

    func testRegularPlaceMatcherRequiresObservationAccuracyToFitInsideRadius() {
        let home = KnownLocation(name: "Home", latitude: 53.55, longitude: 9.99, radiusMeters: 120)
        let inside = CLLocationCoordinate2D(latitude: 53.5502, longitude: 9.99)
        XCTAssertEqual(RegularPlaceMatcher.match(coordinate: inside, accuracy: 10, among: [home])?.id, home.id)
        XCTAssertNil(RegularPlaceMatcher.match(coordinate: inside, accuracy: 100, among: [home]))
        XCTAssertNil(RegularPlaceMatcher.match(coordinate: inside, accuracy: -1, among: [home]))
    }

    func testOverlappingRegularPlacesChooseNearestWithStableTieBreak() {
        let center = CLLocationCoordinate2D(latitude: 53.55, longitude: 9.99)
        let farther = KnownLocation(name: "Farther", latitude: 53.5504, longitude: 9.99, radiusMeters: 200)
        let nearer = KnownLocation(name: "Nearer", latitude: 53.5501, longitude: 9.99, radiusMeters: 200)
        XCTAssertEqual(RegularPlaceMatcher.match(coordinate: center, accuracy: 5, among: [farther, nearer])?.id, nearer.id)
    }

    func testRegularPlaceRadiusShrinkClearsOnlyItsAutomaticAssignment() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let automatic = makePlace(title: "", arrival: start, departure: nil)
        automatic.latitude = 53.551
        automatic.longitude = 9.99
        automatic.horizontalAccuracy = 5
        let manual = makePlace(title: "Home", arrival: start, departure: nil)
        manual.latitude = 53.551
        manual.longitude = 9.99
        manual.horizontalAccuracy = 5
        let home = KnownLocation(name: "Home", latitude: 53.55, longitude: 9.99, radiusMeters: 200)
        automatic.regularPlaceID = home.id
        automatic.regularPlaceName = home.name

        home.radiusMeters = 50
        KnownLocationLabeler.reconcile(location: home, replacedID: home.id, definitions: [home], to: [automatic, manual])

        XCTAssertNil(automatic.regularPlaceID)
        XCTAssertNil(automatic.regularPlaceName)
        XCTAssertEqual(manual.userLabel, "Home")
    }

    @MainActor
    func testNewVisitUsesKnownLocationNameAndRadius() throws {
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
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(KnownLocation(
            name: "Home",
            latitude: 53.5500,
            longitude: 9.9900,
            radiusMeters: 200
        ))
        try context.save()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let visit = MockVisit(
            coordinate: CLLocationCoordinate2D(latitude: 53.5505, longitude: 9.9900),
            horizontalAccuracy: 15,
            arrivalDate: start,
            departureDate: start.addingTimeInterval(1_800)
        )

        let savedPlace = try repository.addOrUpdateVisit(from: visit)

        XCTAssertNil(savedPlace.userLabel)
        XCTAssertEqual(savedPlace.regularPlaceName, "Home")
    }

    @MainActor
    func testManualVisitLabelDoesNotSeedFutureRegularPlaceInference() throws {
        let schema = Schema([DayTimeline.self, VisitPlace.self, KnownLocation.self, MoveSegment.self, LocationSample.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(VisitPlace(
            arrivalDate: start,
            departureDate: start.addingTimeInterval(600),
            latitude: 53.5500,
            longitude: 9.9900,
            horizontalAccuracy: 5,
            userLabel: "Home"
        ))
        try context.save()

        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let visit = MockVisit(
            coordinate: CLLocationCoordinate2D(latitude: 53.5510, longitude: 9.9900),
            horizontalAccuracy: 5,
            arrivalDate: start.addingTimeInterval(3_600),
            departureDate: start.addingTimeInterval(4_200)
        )

        let savedPlace = try repository.addOrUpdateVisit(from: visit)

        XCTAssertNil(savedPlace.userLabel)
        XCTAssertNil(savedPlace.regularPlaceName)
        XCTAssertNil(savedPlace.regularPlaceID)
    }

    func testMostVisitedLocationsAggregateRepeatedLabelsAndDurations() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let firstHomeVisit = makePlace(
            title: "Home",
            arrival: start,
            departure: start.addingTimeInterval(60 * 60)
        )
        let secondHomeVisit = makePlace(
            title: "home",
            arrival: start.addingTimeInterval(24 * 60 * 60),
            departure: start.addingTimeInterval(26 * 60 * 60)
        )
        let officeVisit = makePlace(
            title: "Office",
            arrival: start.addingTimeInterval(4 * 60 * 60),
            departure: start.addingTimeInterval(5 * 60 * 60)
        )
        let timeline = DayTimeline(dayStart: start)
        timeline.places = [firstHomeVisit, officeVisit, secondHomeVisit]

        let snapshot = MovesStatisticsSnapshot(
            dayTimelines: [timeline],
            now: start.addingTimeInterval(48 * 60 * 60)
        )

        let home = try XCTUnwrap(snapshot.locations.first(where: { $0.title.lowercased() == "home" }))
        XCTAssertEqual(home.visitCount, 2)
        XCTAssertEqual(home.totalDuration, 3 * 60 * 60, accuracy: 0.1)
        XCTAssertEqual(snapshot.locations.first?.id, home.id)
    }

    func testVisitSearchMatchesLocationAndComment() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let hamburg = makePlace(
            title: "Hamburg",
            arrival: start,
            departure: start.addingTimeInterval(60 * 60),
            comment: "Weekend with friends"
        )
        let timeline = DayTimeline(dayStart: start)
        timeline.places = [hamburg]
        let snapshot = MovesStatisticsSnapshot(dayTimelines: [timeline])

        XCTAssertEqual(snapshot.filteredVisits(matching: "Hamburg").map(\.id), [hamburg.id])
        XCTAssertEqual(snapshot.filteredVisits(matching: "friends").map(\.id), [hamburg.id])
        XCTAssertTrue(snapshot.filteredVisits(matching: "Bremen").isEmpty)
    }

    func testIndirectConnectionCombinesConsecutiveLegsAndStopTime() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let hamburg = makePlace(title: "Hamburg", arrival: start.addingTimeInterval(-3_600), departure: start)
        let hanover = makePlace(
            title: "Hanover",
            arrival: start.addingTimeInterval(1_200),
            departure: start.addingTimeInterval(1_800)
        )
        let bremen = makePlace(title: "Bremen", arrival: start.addingTimeInterval(3_600), departure: nil)

        let firstLeg = makeMove(
            from: hamburg,
            to: hanover,
            start: start,
            end: start.addingTimeInterval(1_200),
            distance: 150_000
        )
        let secondLeg = makeMove(
            from: hanover,
            to: bremen,
            start: start.addingTimeInterval(1_800),
            end: start.addingTimeInterval(3_600),
            distance: 130_000
        )

        let timeline = DayTimeline(dayStart: start)
        timeline.places = [hamburg, hanover, bremen]
        timeline.moves = [firstLeg, secondLeg]
        let snapshot = MovesStatisticsSnapshot(dayTimelines: [timeline])
        let originKey = MovesStatisticsSnapshot.locationKey(hamburg)
        let destinationKey = MovesStatisticsSnapshot.locationKey(bremen)

        XCTAssertTrue(snapshot.journeys(
            from: originKey,
            to: destinationKey,
            includingIndirect: false
        ).isEmpty)

        let journeys = snapshot.journeys(
            from: originKey,
            to: destinationKey,
            includingIndirect: true
        )
        let journey = try XCTUnwrap(journeys.first)
        XCTAssertEqual(journey.legs.count, 2)
        XCTAssertEqual(journey.duration, 3_600, accuracy: 0.1)
        XCTAssertEqual(journey.distanceMeters, 280_000, accuracy: 0.1)
    }

    func testConnectionStatisticsCalculateMinimumAverageAndMaximum() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let firstHome = makePlace(title: "Home", arrival: start.addingTimeInterval(-1_000), departure: start)
        let firstWork = makePlace(title: "Work", arrival: start.addingTimeInterval(1_200), departure: start.addingTimeInterval(3_000))
        let secondHome = makePlace(title: "Home", arrival: start.addingTimeInterval(4_000), departure: start.addingTimeInterval(5_000))
        let secondWork = makePlace(title: "Work", arrival: start.addingTimeInterval(7_400), departure: nil)

        let quickCommute = makeMove(
            from: firstHome,
            to: firstWork,
            start: start,
            end: start.addingTimeInterval(1_200),
            distance: 10_000
        )
        let slowCommute = makeMove(
            from: secondHome,
            to: secondWork,
            start: start.addingTimeInterval(5_000),
            end: start.addingTimeInterval(7_400),
            distance: 10_000
        )

        let timeline = DayTimeline(dayStart: start)
        timeline.places = [firstHome, firstWork, secondHome, secondWork]
        timeline.moves = [quickCommute, slowCommute]
        let snapshot = MovesStatisticsSnapshot(dayTimelines: [timeline])
        let journeys = snapshot.journeys(
            from: MovesStatisticsSnapshot.locationKey(firstHome),
            to: MovesStatisticsSnapshot.locationKey(firstWork),
            includingIndirect: true
        )
        let statistics = MovesConnectionStatistics(journeys: journeys)

        XCTAssertEqual(journeys.count, 2)
        XCTAssertEqual(try XCTUnwrap(statistics.minimumDuration), 1_200, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(statistics.averageDuration), 1_800, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(statistics.maximumDuration), 2_400, accuracy: 0.1)
        XCTAssertEqual(statistics.minimumJourney?.legs.first?.id, quickCommute.id)
        XCTAssertEqual(statistics.maximumJourney?.legs.first?.id, slowCommute.id)

        slowCommute.isExcludedFromConnectionStatistics = true
        let statisticsWithoutOutlier = MovesConnectionStatistics(journeys: journeys)

        XCTAssertEqual(statisticsWithoutOutlier.journeys.count, 1)
        XCTAssertEqual(try XCTUnwrap(statisticsWithoutOutlier.minimumDuration), 1_200, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(statisticsWithoutOutlier.averageDuration), 1_200, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(statisticsWithoutOutlier.maximumDuration), 1_200, accuracy: 0.1)
    }

    private func makePlace(
        title: String,
        arrival: Date,
        departure: Date?,
        comment: String? = nil
    ) -> VisitPlace {
        VisitPlace(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: 53.0,
            longitude: 10.0,
            horizontalAccuracy: 10,
            userLabel: title,
            comment: comment
        )
    }

    private func makeMove(
        from startPlace: VisitPlace,
        to endPlace: VisitPlace,
        start: Date,
        end: Date,
        distance: Double
    ) -> MoveSegment {
        let move = MoveSegment(
            dedupeKey: UUID().uuidString,
            startDate: start,
            endDate: end,
            transportMode: .train,
            distanceMeters: distance,
            stepCount: nil
        )
        move.startPlace = startPlace
        move.endPlace = endPlace
        return move
    }
}

private struct LegacyTimelineDaySummaryForTest: Codable {
    let dayStart: Date

    var placeCount = 2
    var uniquePlaceCount = 1
    var moveCount = 3
    var sampleCount = 4
    var totalDistanceMeters = 5.0
    var totalMoveDuration = 6.0
    var transportDistanceMeters: [String: Double] = ["walking": 5]
    var transportDuration: [String: TimeInterval] = ["walking": 6]
    var hasImportedRouteData = false
}
