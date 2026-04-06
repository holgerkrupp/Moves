import XCTest
import CoreLocation
import SwiftData
@testable import Moves

@MainActor
final class TimelineAssemblerTests: XCTestCase {
    func testLocationSamplesAreDeduplicatedForSameRoundedSignature() throws {
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
        _ = try repository.appendSamples(from: [location], source: .significantChange)

        let samples = try repository.samples(
            from: timestamp.addingTimeInterval(-30),
            to: timestamp.addingTimeInterval(30)
        )

        XCTAssertEqual(samples.count, 1)
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

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            MoveSegment.self,
            LocationSample.self,
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
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
