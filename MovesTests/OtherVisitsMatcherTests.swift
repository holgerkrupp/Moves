import XCTest
@testable import Moves

final class OtherVisitsMatcherTests: XCTestCase {
    func testEditingVisitLabelDoesNotRenameOrUnlinkRegularPlaceOrComment() {
        let location = KnownLocation(name: "Home", latitude: 10, longitude: 20, radiusMeters: 150)
        let visit = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: 1_700_000_000),
            departureDate: Date(timeIntervalSince1970: 1_700_003_600),
            latitude: 10,
            longitude: 20,
            horizontalAccuracy: 8
        )
        visit.regularPlaceID = location.id
        visit.regularPlaceName = location.name
        visit.comment = "Keep this note"

        VisitPlaceLabelMutation.apply(" Work ", to: visit)

        XCTAssertEqual(visit.userLabel, "Work")
        XCTAssertEqual(visit.regularPlaceID, location.id)
        XCTAssertEqual(visit.regularPlaceName, "Home")
        XCTAssertEqual(visit.comment, "Keep this note")
        XCTAssertEqual(location.name, "Home")
    }

    private let placeID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!

    func testIncludesAuthoritativeIdentityAndNearbyUnclassifiedHistory() {
        let reference = visit(id: 1, day: 10, regularPlaceID: placeID)
        let authoritativeFarAway = visit(id: 2, day: 8, latitude: 42, longitude: 42, regularPlaceID: placeID)
        let nearbyLegacy = visit(id: 3, day: 9, latitude: 0, longitude: 0.0002)
        let nearbyDifferentPlace = visit(id: 4, day: 7, latitude: 0, longitude: 0.0001, regularPlaceID: UUID())

        let result = OtherVisitsMatcher.matchingVisits(
            [nearbyLegacy, authoritativeFarAway, reference, nearbyDifferentPlace],
            reference: reference,
            regularPlace: definition()
        )

        XCTAssertEqual(result.map(\.id), [nearbyLegacy.id, authoritativeFarAway.id])
    }

    func testFallbackUsesConservativeDistanceAndAccuracyAndExcludesReference() {
        let reference = visit(id: 1, day: 10, latitude: 0, longitude: 0)
        let close = visit(id: 2, day: 9, latitude: 0, longitude: 0.0005, accuracy: 30)
        let moderateUncertainty = visit(id: 3, day: 8, latitude: 0, longitude: 0.0005, accuracy: 50)
        let badAccuracy = visit(id: 4, day: 7, latitude: 0, longitude: 0.0013, accuracy: 500)
        let far = visit(id: 5, day: 6, latitude: 0, longitude: 0.004)

        let result = OtherVisitsMatcher.matchingVisits(
            [reference, far, badAccuracy, moderateUncertainty, close],
            reference: reference,
            regularPlace: nil
        )

        XCTAssertEqual(result.map(\.id), [close.id])
    }

    func testDeduplicatesByIDAndSortsNewestFirstWithStableEqualDateTieBreak() {
        let reference = visit(id: 90, day: 20, regularPlaceID: placeID)
        let firstTie = visit(id: 2, day: 15, regularPlaceID: placeID)
        let secondTie = visit(id: 1, day: 15, regularPlaceID: placeID)
        let olderWithMissingDeparture = visit(id: 3, day: 14, regularPlaceID: placeID, departureDate: nil)

        let result = OtherVisitsMatcher.matchingVisits(
            [olderWithMissingDeparture, secondTie, firstTie, firstTie, reference],
            reference: reference,
            regularPlace: definition()
        )

        XCTAssertEqual(result.map(\.id), [secondTie.id, firstTie.id, olderWithMissingDeparture.id])
        XCTAssertNil(result.last?.departureDate)
    }

    func testSavedPlaceIncludesHistoricalUnclassifiedVisitsAcrossYears() {
        let reference = visit(id: 1, day: 100, regularPlaceID: placeID)
        let old = visit(id: 2, day: 1, regularPlaceID: nil)
        let current = visit(id: 3, day: 90, regularPlaceID: placeID)
        XCTAssertNil(old.regularPlaceID)
        XCTAssertEqual(old.latitude, 0)
        XCTAssertEqual(old.longitude, 0)
        XCTAssertEqual(old.horizontalAccuracy, 10)

        let result = OtherVisitsMatcher.matchingVisits(
            [old, current],
            reference: reference,
            regularPlace: definition()
        )

        XCTAssertEqual(result.map(\.id), [current.id, old.id])
    }

    func testInvalidReferenceOrCandidateFixDoesNotCreateGeospatialMatch() {
        let reference = visit(id: 1, day: 10, latitude: .nan, longitude: 0, accuracy: 10)
        let nearby = visit(id: 2, day: 9, latitude: 0, longitude: 0, accuracy: 10)
        let invalidCandidate = visit(id: 3, day: 8, latitude: 0, longitude: 0, accuracy: .nan)

        let result = OtherVisitsMatcher.matchingVisits(
            [nearby, invalidCandidate],
            reference: reference,
            regularPlace: nil
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testAuthoritativeIdentityStillMatchesWhenCandidateCoordinateIsInvalid() {
        let reference = visit(id: 1, day: 10, regularPlaceID: placeID)
        let invalidAuthoritativeVisit = visit(
            id: 2,
            day: 9,
            latitude: .nan,
            longitude: 0,
            accuracy: .nan,
            regularPlaceID: placeID
        )

        let result = OtherVisitsMatcher.matchingVisits(
            [invalidAuthoritativeVisit],
            reference: reference,
            regularPlace: definition()
        )

        XCTAssertEqual(result.map(\.id), [invalidAuthoritativeVisit.id])
    }

    private func definition() -> RegularPlaceDefinitionDTO {
        RegularPlaceDefinitionDTO(id: placeID, name: "Home", latitude: 0, longitude: 0, radiusMeters: 100)
    }

    private func visit(
        id: Int,
        day: Int,
        latitude: Double = 0,
        longitude: Double = 0,
        accuracy: Double = 10,
        regularPlaceID: UUID? = nil,
        departureDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> RegularPlaceVisitDTO {
        let model = VisitPlace(
            arrivalDate: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
            departureDate: departureDate,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: accuracy
        )
        model.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!
        model.regularPlaceID = regularPlaceID
        model.regularPlaceName = regularPlaceID == placeID ? "Home" : nil
        return RegularPlaceVisitDTO(model)
    }
}
