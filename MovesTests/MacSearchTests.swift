import XCTest
@testable import Moves

final class MacSearchTests: XCTestCase {
    func testLocationSearchMatchesAutomaticNameBehindCustomLabel() {
        let place = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_000_000),
            departureDate: nil,
            latitude: -33.8568,
            longitude: 151.2153,
            horizontalAccuracy: 20,
            userLabel: "Sydney",
            autoLabel: "Sydney Opera House"
        )

        XCTAssertTrue(place.matches(searchQuery: "Sydney"))
        XCTAssertTrue(place.matches(searchQuery: "Opera House"))
        XCTAssertFalse(place.matches(searchQuery: "Harbour Bridge"))
    }
}
