#if DEBUG

import CoreLocation
import XCTest
@testable import Moves

final class PhotosIntegrationDebugTests: XCTestCase {
    func testSeveralPhotosAtOnePlaceBecomeOneCandidateVisit() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let records = (0..<4).map { index in
            PhotoMetadataRecord(
                id: "museum-\(index)",
                creationDate: start.addingTimeInterval(TimeInterval(index * 20 * 60)),
                latitude: 53.5505 + Double(index) * 0.0001,
                longitude: 9.9930,
                horizontalAccuracy: 12,
                mediaType: 1
            )
        }

        let candidates = PhotoVisitClusterer.cluster(records)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].assetIDs.count, 4)
    }

    func testTemporallySeparateEventsRemainSeparate() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            PhotoMetadataRecord(id: "first-a", creationDate: start, latitude: 53.55, longitude: 9.99, horizontalAccuracy: 10, mediaType: 1),
            PhotoMetadataRecord(id: "first-b", creationDate: start.addingTimeInterval(10 * 60), latitude: 53.55, longitude: 9.99, horizontalAccuracy: 10, mediaType: 1),
            PhotoMetadataRecord(id: "second-a", creationDate: start.addingTimeInterval(3 * 60 * 60), latitude: 53.55, longitude: 9.99, horizontalAccuracy: 10, mediaType: 1),
            PhotoMetadataRecord(id: "second-b", creationDate: start.addingTimeInterval(3 * 60 * 60 + 10 * 60), latitude: 53.55, longitude: 9.99, horizontalAccuracy: 10, mediaType: 1)
        ]

        XCTAssertEqual(PhotoVisitClusterer.cluster(records).count, 2)
    }

    func testTravellingPhotosDoNotCreateArtificialVisits() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            PhotoMetadataRecord(id: "a", creationDate: start, latitude: 53.55, longitude: 9.99, horizontalAccuracy: 10, mediaType: 1),
            PhotoMetadataRecord(id: "b", creationDate: start.addingTimeInterval(60), latitude: 53.60, longitude: 10.00, horizontalAccuracy: 10, mediaType: 1),
            PhotoMetadataRecord(id: "c", creationDate: start.addingTimeInterval(120), latitude: 53.65, longitude: 10.01, horizontalAccuracy: 10, mediaType: 1)
        ]

        XCTAssertTrue(PhotoVisitClusterer.cluster(records).isEmpty)
    }

    func testExactAndInterpolatedMatchesAreConservative() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let exact = PhotoLocationMatcher.match(
            date: date,
            samples: [PhotoLocationTimelinePoint(date: date.addingTimeInterval(30), coordinate: coordinate(53.55, 9.99))],
            visits: []
        )
        XCTAssertEqual(exact?.confidence, .exact)

        let interpolated = PhotoLocationMatcher.match(
            date: date,
            samples: [
                PhotoLocationTimelinePoint(date: date.addingTimeInterval(-300), coordinate: coordinate(53.55, 9.99)),
                PhotoLocationTimelinePoint(date: date.addingTimeInterval(300), coordinate: coordinate(53.56, 10.00))
            ],
            visits: []
        )
        XCTAssertEqual(interpolated?.confidence, .interpolated)
        XCTAssertEqual(interpolated?.latitude ?? 0, 53.555, accuracy: 0.0001)
    }

    func testLargeGapAndDiscontinuousSamplesAreSkipped() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let gap = PhotoLocationMatcher.match(
            date: date,
            samples: [
                PhotoLocationTimelinePoint(date: date.addingTimeInterval(-20 * 60), coordinate: coordinate(53.55, 9.99)),
                PhotoLocationTimelinePoint(date: date.addingTimeInterval(20 * 60), coordinate: coordinate(53.56, 10.00))
            ],
            visits: []
        )
        XCTAssertNil(gap)

        let teleport = PhotoLocationMatcher.match(
            date: date,
            samples: [
                PhotoLocationTimelinePoint(date: date.addingTimeInterval(-300), coordinate: coordinate(53.55, 9.99)),
                PhotoLocationTimelinePoint(date: date.addingTimeInterval(300), coordinate: coordinate(60.00, 20.00))
            ],
            visits: []
        )
        XCTAssertNil(teleport)
    }

    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

#endif
