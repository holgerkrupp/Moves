import CoreLocation
import XCTest
@testable import Moves

final class ImportedTransportModeInferenceTests: XCTestCase {
    func testAutomaticPlanePolicyKeepsExactBoundaryOutOfLongDistanceRule() {
        let exactBoundary = MotionClassificationEvidence(
            motionCandidate: .unknown,
            observedSpeeds: [],
            directDistance: 1_000_000,
            elapsedTime: 60 * 60,
            timingConfidence: .low
        )

        XCTAssertEqual(
            AutomaticPlaneResolver.resolve(FlightInferenceEvidence(motion: exactBoundary)),
            .unknown
        )
    }

    func testAutomaticPlanePolicyAcceptsJustOverThousandKilometres() {
        let evidence = MotionClassificationEvidence(
            motionCandidate: .unknown,
            observedSpeeds: [],
            directDistance: 1_000_001,
            elapsedTime: 60 * 60,
            timingConfidence: .low
        )

        XCTAssertEqual(
            AutomaticPlaneResolver.resolve(FlightInferenceEvidence(motion: evidence)),
            .plane
        )
    }

    func testWeakSparseLocalPlaneCandidateDoesNotBecomeFlight() {
        let evidence = MotionClassificationEvidence(
            motionCandidate: .plane,
            observedSpeeds: [],
            directDistance: 2_200,
            elapsedTime: 20,
            timingConfidence: .low
        )

        XCTAssertEqual(
            AutomaticPlaneResolver.resolve(FlightInferenceEvidence(motion: evidence)),
            .unknown
        )
    }

    func testShortCyclingRouteOverridesImpossibleSparseSpeedCandidate() {
        let evidence = MotionClassificationEvidence(
            motionCandidate: .plane,
            observedSpeeds: [90, 92],
            directDistance: 2_200,
            elapsedTime: 20,
            timingConfidence: .low
        )
        let flightEvidence = FlightInferenceEvidence(
            motion: evidence,
            terrestrialRouteEvidence: .routeFound(
                mode: .cycling,
                distance: 2_600,
                expectedTravelTime: 8 * 60
            )
        )

        XCTAssertEqual(AutomaticPlaneResolver.resolve(flightEvidence), .cycling)
    }

    func testSubThousandKilometreJourneyCanUseStrongElapsedTimeEvidence() {
        let evidence = MotionClassificationEvidence(
            motionCandidate: .automotive,
            observedSpeeds: [],
            directDistance: 600_000,
            elapsedTime: 45 * 60,
            timingConfidence: .high
        )

        XCTAssertEqual(
            AutomaticPlaneResolver.resolve(
                FlightInferenceEvidence(
                    motion: evidence,
                    terrestrialRouteEvidence: .unavailableOrTransientFailure
                )
            ),
            .plane
        )
    }

    func testAntimeridianPolylineContainsBoundaryIntersections() {
        let segments = RouteCoordinateOps.mapPolylineSegments([
            CLLocationCoordinate2D(latitude: 10, longitude: 170),
            CLLocationCoordinate2D(latitude: 12, longitude: -170)
        ])

        XCTAssertEqual(segments.count, 2)
        guard let firstBoundary = segments[0].last,
              let secondBoundary = segments[1].first else {
            XCTFail("Expected antimeridian boundary points")
            return
        }
        XCTAssertEqual(firstBoundary.longitude, 180, accuracy: 0.0001)
        XCTAssertEqual(secondBoundary.longitude, -180, accuracy: 0.0001)
        XCTAssertEqual(firstBoundary.latitude, secondBoundary.latitude, accuracy: 0.0001)
    }

    func testInfersPlaneFromCruiseAltitude() {
        let route = makeRoute(
            coordinates: [(48.35, 11.79), (49.5, 8.6), (50.04, 8.56)],
            altitudes: [500, 10_000, 200],
            interval: 30 * 60
        )

        XCTAssertEqual(ImportedTransportModeInference.infer(from: route), .plane)
    }

    func testInfersPlaneWithoutAltitudeFromSustainedFlightSpeed() {
        let route = makeRoute(
            coordinates: [(48.35, 11.79), (51.0, 5.0), (52.31, 4.76)],
            altitudes: [0, 0, 0],
            interval: 35 * 60
        )

        XCTAssertEqual(ImportedTransportModeInference.infer(from: route), .plane)
    }

    func testInfersWalkingFromSlowDetailedTrack() {
        let route = makeRoute(
            coordinates: [
                (52.5200, 13.4050), (52.5225, 13.4075), (52.5250, 13.4100),
                (52.5275, 13.4125), (52.5300, 13.4150),
            ],
            altitudes: [35, 35, 36, 36, 35],
            interval: 4 * 60
        )

        XCTAssertEqual(ImportedTransportModeInference.infer(from: route), .walking)
    }

    func testLeavesAmbiguousSparseRouteUnknown() {
        let route = makeRoute(
            coordinates: [(52.5200, 13.4050), (52.5300, 13.4150)],
            altitudes: [0, 0],
            interval: 20 * 60
        )

        XCTAssertNil(ImportedTransportModeInference.infer(from: route))
    }

    private func makeRoute(
        coordinates: [(Double, Double)],
        altitudes: [Double],
        interval: TimeInterval
    ) -> [CLLocation] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return zip(coordinates, altitudes).enumerated().map { index, value in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: value.0.0, longitude: value.0.1),
                altitude: value.1,
                horizontalAccuracy: 5,
                verticalAccuracy: value.1 == 0 ? -1 : 5,
                course: -1,
                speed: -1,
                timestamp: start.addingTimeInterval(Double(index) * interval)
            )
        }
    }
}
