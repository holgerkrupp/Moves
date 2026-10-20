import CoreLocation
import SwiftData
import XCTest
@testable import Moves

@MainActor
final class TimelineDayPresentationStagingTests: XCTestCase {
    func testFirstPaintSnapshotDefersRouteGeometryAndExactCounts() async throws {
        let schema = Schema([DayTimeline.self, VisitPlace.self, KnownLocation.self, MoveSegment.self, LocationSample.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let dayStart = Date(timeIntervalSince1970: 1_790_000_000)
        let move = MoveSegment(
            dedupeKey: "staged-imported-route",
            startDate: dayStart.addingTimeInterval(60),
            endDate: dayStart.addingTimeInterval(600),
            transportMode: .train,
            distanceMeters: 12_000,
            stepCount: nil
        )
        let imported = [
            CLLocation(latitude: 52.5200, longitude: 13.4050),
            CLLocation(latitude: 52.5300, longitude: 13.4150),
            CLLocation(latitude: 52.5400, longitude: 13.4250)
        ]
        move.importedRouteData = ImportedRoutePayloadCodec.encode(imported)
        container.mainContext.insert(move)
        try container.mainContext.save()

        let snapshot = try await TimelineDayPresentationWorker(modelContainer: container).snapshot(
            dayStart: dayStart,
            includeExactCounts: false,
            includeRouteGeometry: false
        )
        let moveSnapshot = try XCTUnwrap(snapshot.moves.first)

        XCTAssertFalse(snapshot.countsAreExact)
        XCTAssertEqual(moveSnapshot.rawRouteCoordinates, [])
        XCTAssertNotNil(snapshot.routeGeometryInputs.first?.importedRouteData)
        XCTAssertEqual(snapshot.routeGeometryInputs.first?.moveID, move.id)
    }

    func testDeferredImportedGeometryPreparationPreservesRecordedCoordinates() async throws {
        let imported = [
            CLLocation(latitude: 52.5200, longitude: 13.4050),
            CLLocation(latitude: 52.5300, longitude: 13.4150),
            CLLocation(latitude: 52.5400, longitude: 13.4250)
        ]
        let moveID = UUID()
        let input = TimelineMoveRouteGeometryInput(
            moveID: moveID,
            importedRouteData: ImportedRoutePayloadCodec.encode(imported),
            startPlace: nil,
            endPlace: nil,
            samples: [],
            usesHealthWorkoutRoute: false
        )

        let prepared = try XCTUnwrap(try await TimelineRouteGeometryPreparer.prepare([input]).first)

        XCTAssertEqual(prepared.moveID, moveID)
        XCTAssertEqual(prepared.rawCoordinates.map(\.latitude), imported.map { $0.coordinate.latitude })
        XCTAssertEqual(prepared.rawCoordinates.map(\.longitude), imported.map { $0.coordinate.longitude })
    }

    func testDeferredRawFixPreparationUsesOnlyRecordedSamplesAndKeepsEndpoints() async throws {
        let start = TimelinePlaceSnapshot(
            id: UUID(), deviceIdentifier: "device", arrivalDate: .distantPast,
            departureDate: nil, latitude: 52.5, longitude: 13.4, horizontalAccuracy: 5,
            userLabel: nil, regularPlaceID: nil, regularPlaceName: nil, autoLabel: nil,
            comment: nil, dayKey: nil
        )
        let end = TimelinePlaceSnapshot(
            id: UUID(), deviceIdentifier: "device", arrivalDate: .distantFuture,
            departureDate: nil, latitude: 52.52, longitude: 13.42, horizontalAccuracy: 5,
            userLabel: nil, regularPlaceID: nil, regularPlaceName: nil, autoLabel: nil,
            comment: nil, dayKey: nil
        )
        let samples = [
            TimelineSampleSnapshot(
                dedupeKey: "fix", deviceIdentifier: "device", timestamp: Date(),
                latitude: 52.51, longitude: 13.41, altitude: 0, horizontalAccuracy: 5,
                speed: 1, sourceRawValue: LocationSampleSource.significantChange.rawValue,
                moveID: nil
            )
        ]
        let input = TimelineMoveRouteGeometryInput(
            moveID: UUID(), importedRouteData: nil, startPlace: start, endPlace: end,
            samples: samples, usesHealthWorkoutRoute: false
        )

        let prepared = try XCTUnwrap(try await TimelineRouteGeometryPreparer.prepare([input]).first)

        XCTAssertEqual(prepared.rawCoordinates.count, 3)
        XCTAssertEqual(prepared.rawCoordinates.first?.latitude, start.latitude)
        XCTAssertEqual(prepared.rawCoordinates.last?.longitude, end.longitude)
    }
}
