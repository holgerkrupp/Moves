import CoreLocation
import SwiftData
import XCTest
@testable import Moves

final class RegularPlaceQueryWorkerTests: XCTestCase {
    @MainActor
    func testSpatialPagesApplyAccuracyFilterBeforeOffsetAndKeepNilDeparture() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let center = KnownLocation(name: "Home", latitude: 53.55, longitude: 9.99, radiusMeters: 150)
        context.insert(center)
        let dates = [Date(timeIntervalSince1970: 300), Date(timeIntervalSince1970: 200), Date(timeIntervalSince1970: 100)]
        let visits = [
            VisitPlace(arrivalDate: dates[0], departureDate: nil, latitude: 53.5501, longitude: 9.99, horizontalAccuracy: 5),
            VisitPlace(arrivalDate: dates[1], departureDate: dates[1].addingTimeInterval(50), latitude: 53.5502, longitude: 9.99, horizontalAccuracy: 5),
            VisitPlace(arrivalDate: dates[2], departureDate: nil, latitude: 53.5505, longitude: 9.99, horizontalAccuracy: 100),
        ]
        visits.forEach(context.insert)
        try context.save()

        let worker = RegularPlaceQueryWorker(modelContainer: container)
        let first = try await worker.visits(nearLatitude: center.latitude, longitude: center.longitude,
                                            radiusMeters: center.radiusMeters, offset: 0, limit: 1)
        let second = try await worker.visits(nearLatitude: center.latitude, longitude: center.longitude,
                                             radiusMeters: center.radiusMeters, offset: first.nextOffset, limit: 1)

        XCTAssertEqual(first.visits.map(\.id), [visits[0].id])
        XCTAssertEqual(second.visits.map(\.id), [visits[1].id])
        XCTAssertNil(first.visits.first?.departureDate)
        XCTAssertFalse(second.hasMore)
    }

    @MainActor
    func testHistoryPageUnionsIdentityAndUnclassifiedSpatialMatchesOnce() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let location = KnownLocation(name: "Home", latitude: 53.55, longitude: 9.99, radiusMeters: 150)
        context.insert(location)
        let older = VisitPlace(arrivalDate: Date(timeIntervalSince1970: 100), departureDate: nil,
                               latitude: 53.5501, longitude: 9.99, horizontalAccuracy: 5)
        let newer = VisitPlace(arrivalDate: Date(timeIntervalSince1970: 200), departureDate: nil,
                               latitude: 54, longitude: 10, horizontalAccuracy: 5)
        newer.regularPlaceID = location.id
        newer.regularPlaceName = location.name
        let outside = VisitPlace(arrivalDate: Date(timeIntervalSince1970: 300), departureDate: nil,
                                 latitude: 53.552, longitude: 9.99, horizontalAccuracy: 20)
        context.insert(older)
        context.insert(newer)
        context.insert(outside)
        try context.save()

        let worker = RegularPlaceQueryWorker(modelContainer: container)
        let page = try await worker.historyVisits(regularPlaceID: location.id,
                                                  definition: RegularPlaceDefinitionDTO(location), offset: 0, limit: 1)
        let next = try await worker.historyVisits(regularPlaceID: location.id,
                                                  definition: RegularPlaceDefinitionDTO(location), offset: page.nextOffset, limit: 1)

        XCTAssertEqual(page.visits.map(\.id), [newer.id])
        XCTAssertEqual(next.visits.map(\.id), [older.id])
        XCTAssertFalse(next.hasMore)
    }

    @MainActor
    func testCountsAndReconciliationPreserveManualLabelsAndCommentsAcrossOverlap() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let oldLocation = KnownLocation(name: "Home", latitude: 53.55, longitude: 9.99, radiusMeters: 200)
        let overlap = KnownLocation(name: "Nearby", latitude: 53.5501, longitude: 9.99, radiusMeters: 200)
        context.insert(oldLocation)
        context.insert(overlap)
        let automatic = VisitPlace(arrivalDate: Date(timeIntervalSince1970: 100), departureDate: nil,
                                   latitude: 53.551, longitude: 9.99, horizontalAccuracy: 5)
        automatic.regularPlaceID = oldLocation.id
        automatic.regularPlaceName = oldLocation.name
        let manual = VisitPlace(arrivalDate: Date(timeIntervalSince1970: 200), departureDate: nil,
                                latitude: 53.5501, longitude: 9.99, horizontalAccuracy: 5,
                                userLabel: "Client", comment: "Keep this note")
        manual.regularPlaceID = oldLocation.id
        manual.regularPlaceName = oldLocation.name
        context.insert(automatic)
        context.insert(manual)
        try context.save()

        oldLocation.name = "Home renamed"
        oldLocation.radiusMeters = 50
        try context.save()
        let definitions = [RegularPlaceDefinitionDTO(oldLocation), RegularPlaceDefinitionDTO(overlap)]
        let worker = RegularPlaceQueryWorker(modelContainer: container)
        let counts = try await worker.counts(for: definitions)
        let expectedDayKey = DayTimeline.makeDayKey(for: automatic.arrivalDate)
        let refreshNotification = expectation(forNotification: .movesVisitedPlaceDidChange, object: nil) { notification in
            guard let dayKeys = notification.userInfo?["dayKeys"] as? [String] else { return false }
            XCTAssertEqual(dayKeys, [expectedDayKey])
            return true
        }
        _ = try await worker.reconcile(location: definitions[0], replacedID: oldLocation.id,
                                       definitions: definitions, batchSize: 1)
        await fulfillment(of: [refreshNotification], timeout: 1)

        XCTAssertEqual(counts.first(where: { $0.regularPlaceID == oldLocation.id })?.count, 1)
        let reassigned = try await worker.visits(regularPlaceID: overlap.id).visits.first { $0.id == automatic.id }
        let preserved = try await worker.visits(regularPlaceID: oldLocation.id).visits.first { $0.id == manual.id }
        XCTAssertEqual(reassigned?.regularPlaceID, overlap.id)
        XCTAssertEqual(reassigned?.regularPlaceName, "Nearby")
        XCTAssertEqual(preserved?.userLabel, "Client")
        XCTAssertEqual(preserved?.comment, "Keep this note")
        XCTAssertEqual(preserved?.regularPlaceID, oldLocation.id)
    }

    @MainActor
    func testUnnamedSummaryAggregatesHistoryWithoutUsingCurrentTimeForOpenVisit() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let firstDate = Date(timeIntervalSince1970: 100)
        let first = VisitPlace(arrivalDate: firstDate, departureDate: nil, latitude: 53.5501,
                               longitude: 9.9901, horizontalAccuracy: 5)
        let second = VisitPlace(arrivalDate: firstDate.addingTimeInterval(1_000), departureDate: nil,
                                latitude: 53.5502, longitude: 9.9902, horizontalAccuracy: 5)
        context.insert(first)
        context.insert(second)
        try context.save()

        let worker = RegularPlaceQueryWorker(modelContainer: container)
        let result = try await worker.frequentUnnamedSummaries()

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].visitCount, 2)
        XCTAssertEqual(result[0].totalDuration, 0)
        XCTAssertEqual(result[0].latestArrivalDate, second.arrivalDate)
    }

    @MainActor
    func testReconcileUsesBoundedKeysetPagesWhenOldAssignmentsLeaveTheCandidateSet() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let location = KnownLocation(name: "Home", latitude: 53.55, longitude: 9.99, radiusMeters: 300)
        context.insert(location)
        let base = Date(timeIntervalSince1970: 100)
        for index in 0..<610 {
            let visit = VisitPlace(arrivalDate: base.addingTimeInterval(Double(index % 3)), departureDate: nil,
                                   latitude: 53.551, longitude: 9.99, horizontalAccuracy: 5)
            visit.regularPlaceID = location.id
            visit.regularPlaceName = location.name
            context.insert(visit)
        }
        try context.save()
        let previous = RegularPlaceDefinitionDTO(location)
        location.latitude = 53.7
        location.radiusMeters = 50
        try context.save()

        let worker = RegularPlaceQueryWorker(modelContainer: container)
        let definition = RegularPlaceDefinitionDTO(location)
        let changed = try await worker.reconcile(location: definition, replacedID: location.id,
                                                 previousDefinition: previous, definitions: [definition], batchSize: 37)
        let remaining = try await worker.visits(regularPlaceID: location.id, offset: 0, limit: 1)

        XCTAssertEqual(changed, 610)
        XCTAssertTrue(remaining.visits.isEmpty)
    }

    @MainActor
    func testDatelineSpatialQueryAndDeleteReconciliation() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let location = KnownLocation(name: "Dateline", latitude: 0, longitude: 179.9998, radiusMeters: 100)
        let acrossBoundary = VisitPlace(arrivalDate: Date(timeIntervalSince1970: 100), departureDate: nil,
                                        latitude: 0, longitude: -179.9998, horizontalAccuracy: 5)
        acrossBoundary.regularPlaceID = location.id
        acrossBoundary.regularPlaceName = location.name
        context.insert(location)
        context.insert(acrossBoundary)
        try context.save()

        let worker = RegularPlaceQueryWorker(modelContainer: container)
        let regional = try await worker.visits(nearLatitude: location.latitude, longitude: location.longitude,
                                               radiusMeters: location.radiusMeters)
        XCTAssertEqual(regional.visits.map(\.id), [acrossBoundary.id])
        _ = try await worker.remove(locationID: location.id, definitions: [])
        let remaining = try await worker.visits(regularPlaceID: location.id)
        XCTAssertTrue(remaining.visits.isEmpty)
    }

    @MainActor
    func testInvalidSpatialInputsAreRejected() async throws {
        let container = try makeContainer()
        let worker = RegularPlaceQueryWorker(modelContainer: container)

        do {
            _ = try await worker.visits(nearLatitude: .nan, longitude: 0, radiusMeters: 10)
            XCTFail("Expected invalid coordinate to fail")
        } catch RegularPlaceQueryError.invalidCoordinateOrRadius {
        }
        do {
            _ = try await worker.visits(nearLatitude: 0, longitude: 0, radiusMeters: .infinity)
            XCTFail("Expected non-finite radius to fail")
        } catch RegularPlaceQueryError.invalidCoordinateOrRadius {
        }
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([DayTimeline.self, VisitPlace.self, KnownLocation.self, MoveSegment.self, LocationSample.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
