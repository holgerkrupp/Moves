import XCTest
import CoreLocation
import SwiftData
@testable import Moves

final class MovesStatisticsSearchTests: XCTestCase {
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

    func testRenamingKnownLocationUpdatesMatchingLabelsWithoutOverwritingCustomLabels() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let matchingOldLabel = makePlace(title: "Office", arrival: start, departure: nil)
        let matchingCustomLabel = makePlace(title: "Customer Meeting", arrival: start, departure: nil)
        let location = KnownLocation(
            name: "Work",
            latitude: 53.0,
            longitude: 10.0,
            radiusMeters: 150
        )

        KnownLocationLabeler.apply(
            location: location,
            previousName: "Office",
            to: [matchingOldLabel, matchingCustomLabel]
        )

        XCTAssertEqual(matchingOldLabel.userLabel, "Work")
        XCTAssertEqual(matchingCustomLabel.userLabel, "Customer Meeting")
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

        XCTAssertEqual(savedPlace.userLabel, "Home")
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
