import CoreLocation
import XCTest
@testable import Moves

final class ImportedTransportModeInferenceTests: XCTestCase {
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
