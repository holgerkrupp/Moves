import XCTest
@testable import RouteFileKit
@testable import RoutePreviewKit

final class RouteFileKitTests: XCTestCase {
    func testParsesGPXAndPreservesTimestampMetadata() throws {
        let xml = """
        <gpx><trk><name>walk</name><trkseg>
          <trkpt lat="52.0" lon="13.0"><ele>40</ele><time>2026-01-01T10:00:00Z</time></trkpt>
          <trkpt lat="52.001" lon="13.002"><ele>45</ele><time>2026-01-01T10:01:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let tracks = try RouteFileParser.parse(data: Data(xml.utf8), fileName: "walk.gpx")
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].points.count, 2)
        XCTAssertTrue(tracks[0].hasOriginalTimestamps)
        XCTAssertEqual(tracks[0].transportMode, .walking)
    }

    func testParsesGeoJSONMultiLineStringAndRejectsInvalidCoordinates() throws {
        let json = #"{"type":"MultiLineString","coordinates":[[[13,52],[13.1,52.1]],[[181,52],[13.2,52.2]]]}"#
        let tracks = try RouteFileParser.parse(data: Data(json.utf8), fileName: "route.geojson")
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].points.count, 2)
    }

    func testDatelineSegmentsAndSimplificationPreserveEndpoints() {
        let points = (0..<100).map { index in
            RouteTrackPoint(latitude: Double(index) / 100, longitude: 10 + Double(index) / 100, timestamp: Date(timeIntervalSince1970: Double(index)))
        }
        let tracks = [RouteTrack(points: points, hasOriginalTimestamps: false)]
        let segments = RoutePreviewGeometry.segments(for: tracks, pointBudget: 20)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].points.first, points.first)
        XCTAssertEqual(segments[0].points.last, points.last)
        XCTAssertLessThanOrEqual(segments[0].points.count, 20)
    }

    func testDatelineRegionUsesTheShortWrappedSpan() {
        let points = [
            RouteTrackPoint(latitude: 10, longitude: 179, timestamp: .now),
            RouteTrackPoint(latitude: 10.1, longitude: -179, timestamp: .now.addingTimeInterval(1))
        ]
        let region = RoutePreviewGeometry.fittedRegion(for: [RouteTrack(points: points, hasOriginalTimestamps: false)])!
        XCTAssertLessThan(region.span.longitudeDelta, 10)
        XCTAssertGreaterThan(abs(region.center.longitude), 170)
    }

    func testSummaryUsesOriginalDatesOnly() {
        let points = [
            RouteTrackPoint(latitude: 0, longitude: 0, altitude: 10, hasElevation: true, timestamp: Date(timeIntervalSince1970: 0)),
            RouteTrackPoint(latitude: 0, longitude: 1, altitude: 20, hasElevation: true, timestamp: Date(timeIntervalSince1970: 60))
        ]
        let summary = RoutePreviewSummaries.summary(for: [RouteTrack(points: points, hasOriginalTimestamps: false)])
        XCTAssertNil(summary.startDate)
        XCTAssertNil(summary.duration)
        XCTAssertGreaterThan(summary.distanceMeters, 100_000)
        XCTAssertEqual(summary.elevationGain, 10)
    }
}
