import CoreLocation
import Foundation
import XCTest
import FogOfWorldKit
@testable import Moves

// Both Moves and FogOfWorldKit intentionally expose a bitmap type. Keep the
// test helpers on Moves' canonical bitmap unless a package type is explicit.
typealias FogBitmapBlock = Moves.FogBitmapBlock

final class ExplorationTests: XCTestCase {
    func testFogReferenceVectors() throws {
        let equator = try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        XCTAssertEqual(equator.cell.coordinate, FogRasterCoordinate(x: 2_097_152, y: 2_097_152))
        XCTAssertEqual(equator.baseTile, FogBaseTileID(x: 256, y: 256))
        XCTAssertEqual(equator.block, FogBlockID(x: 32_768, y: 32_768))
        XCTAssertEqual(equator.localCellX, 0)
        XCTAssertEqual(equator.localCellY, 0)

        let munich = try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755))
        XCTAssertEqual(munich.cell.coordinate, FogRasterCoordinate(x: 2_232_016, y: 1_455_604))
        XCTAssertEqual(munich.baseTile, FogBaseTileID(x: 272, y: 177))
        XCTAssertEqual(munich.block, FogBlockID(x: 34_875, y: 22_743))
        XCTAssertEqual(munich.localCellX, 16)
        XCTAssertEqual(munich.localCellY, 52)

        let southern = try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093))
        XCTAssertEqual(southern.baseTile, FogBaseTileID(x: 471, y: 307))
        XCTAssertEqual(southern.block, FogBlockID(x: 60_294, y: 39_327))

        XCTAssertEqual(
            try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: 0, longitude: -180)).cell,
            try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: 0, longitude: 180)).cell
        )
        XCTAssertEqual(try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: 90, longitude: 0)).cell.coordinate.y, 0)
        XCTAssertEqual(try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: -90, longitude: 0)).cell.coordinate.y, FogRasterV1.globalCellDimension - 1)
    }

    func testPresentationProjectionDoesNotChangeCanonicalCellIdentity() throws {
        let coordinate = ExplorationGeographicCoordinate(latitude: 48.1374, longitude: 11.5755)
        let projection = ExplorationWebMercatorProjection()
        let projected = projection.project(coordinate)
        let roundTrip = projection.unproject(projected)
        XCTAssertEqual(roundTrip.latitude, coordinate.latitude, accuracy: 0.0000001)
        XCTAssertEqual(roundTrip.longitude, coordinate.longitude, accuracy: 0.0000001)

        let canonical = try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
        let shiftedPresentation = projection.project(ExplorationGeographicCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude + 360))
        XCTAssertEqual(shiftedPresentation.x, projected.x, accuracy: 0.000000000001)
        XCTAssertEqual(shiftedPresentation.y, projected.y, accuracy: 0.000000000001)
        let canonicalAgain = try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude + 360))
        XCTAssertEqual(canonical.cell, canonicalAgain.cell)
    }

    func testGeopoliticalGroupingKeepsUnknownIDsOutOfUNCount() {
        XCTAssertTrue(ExplorationGeopoliticalPolicy.isUNMember(countryID: "DE"))
        XCTAssertTrue(ExplorationGeopoliticalPolicy.isBroaderEntity(countryID: "GU"))
        XCTAssertFalse(ExplorationGeopoliticalPolicy.isUNMember(countryID: "ZZ"))
        XCTAssertEqual(ExplorationGeopoliticalPolicy.continent(for: "ZZ"), .other)
    }

    func testFlightTicketRecipesAreDeterministicAndDoNotInventMetadata() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let facts = ExplorationFlightFacts(
            moveID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            departureDate: date,
            arrivalDate: date.addingTimeInterval(7_200),
            origin: ExplorationFlightEndpoint(placeName: "Hamburg", countryID: "DE", countryName: "Germany"),
            destination: ExplorationFlightEndpoint(placeName: "Seoul", countryID: "KR", countryName: "South Korea"),
            distanceMeters: 8_000_000
        )
        let first = ExplorationFlightTicketGenerator.make(from: facts)
        let second = ExplorationFlightTicketGenerator.make(from: facts)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.facts.origin.placeName, "Hamburg")
        XCTAssertEqual(first.facts.destination.placeName, "Seoul")
        XCTAssertFalse(first.recipe.decorativeSerial.isEmpty)

        let otherFacts = ExplorationFlightFacts(
            moveID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            departureDate: date,
            arrivalDate: date.addingTimeInterval(7_200),
            origin: facts.origin,
            destination: facts.destination,
            distanceMeters: facts.distanceMeters
        )
        XCTAssertNotEqual(first.recipe, ExplorationFlightTicketGenerator.make(from: otherFacts).recipe)
    }

    func testBitmapBitOrderingAndLineTraversal() throws {
        var bitmap = try FogBitmapBlock()
        bitmap.set(x: 0, y: 0)
        bitmap.set(x: 7, y: 0)
        bitmap.set(x: 63, y: 63)
        XCTAssertEqual(bitmap.data().first, 0b10000001)
        XCTAssertEqual(bitmap.data().last, 0b00000001)
        XCTAssertTrue(bitmap.isSet(x: 0, y: 0))
        XCTAssertTrue(bitmap.isSet(x: 63, y: 63))
        XCTAssertFalse(bitmap.isSet(x: 1, y: 0))

        let line = FogRasterV1.cellsAlongLine(
            from: FogCell(coordinate: FogRasterCoordinate(x: 10, y: 10)),
            to: FogCell(coordinate: FogRasterCoordinate(x: 13, y: 12))
        )
        XCTAssertEqual(line.map { $0.coordinate }, [
            FogRasterCoordinate(x: 10, y: 10),
            FogRasterCoordinate(x: 11, y: 11),
            FogRasterCoordinate(x: 12, y: 11),
            FogRasterCoordinate(x: 13, y: 12)
        ])

        let boundaryX = UInt32(8_192)
        let boundaryLongitude = Double(boundaryX) / Double(FogRasterV1.globalCellDimension) * 360 - 180
        let boundary = try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: 0, longitude: boundaryLongitude))
        XCTAssertEqual(boundary.cell.coordinate.x, boundaryX)
        XCTAssertEqual(boundary.baseTile.x, 1)
        XCTAssertEqual(boundary.block.x, 128)
        XCTAssertEqual(boundary.localCellX, 0)

        let blockBoundaryX = UInt32(32_768)
        let blockBoundaryLongitude = Double(blockBoundaryX) / Double(FogRasterV1.globalCellDimension) * 360 - 180
        let blockBoundary = try FogRasterV1.address(for: CLLocationCoordinate2D(latitude: 0, longitude: blockBoundaryLongitude))
        XCTAssertEqual(blockBoundary.block.x, 512)
        XCTAssertEqual(blockBoundary.localCellX, 0)
    }

    func testCellBoundsAndLatitudeAwareArea() throws {
        let equator = FogCell(coordinate: FogRasterCoordinate(x: 2_097_152, y: 2_097_152))
        let north = FogCell(coordinate: FogRasterCoordinate(x: 2_097_152, y: 1_000_000))
        let bounds = try FogRasterV1.geographicBounds(for: equator)
        XCTAssertLessThan(bounds.south, bounds.north)
        XCTAssertEqual(bounds.east - bounds.west, 360 / Double(FogRasterV1.globalCellDimension), accuracy: 1e-12)
        XCTAssertGreaterThan(try FogRasterV1.areaSquareMeters(for: equator), try FogRasterV1.areaSquareMeters(for: north))
    }

    func testLineRasterizationIncludesCrossedBlockBoundary() {
        let start = FogCell(coordinate: FogRasterCoordinate(x: 63, y: 63))
        let end = FogCell(coordinate: FogRasterCoordinate(x: 65, y: 65))
        let cells = FogRasterV1.cellsAlongLine(from: start, to: end)
        XCTAssertEqual(cells.first, start)
        XCTAssertEqual(cells.last, end)
        XCTAssertTrue(cells.contains(FogCell(coordinate: FogRasterCoordinate(x: 64, y: 64))))
    }

    func testShardRoundTripDeterminismAndCorruption() throws {
        var bitmap = try FogBitmapBlock()
        bitmap.set(x: 0, y: 0)
        bitmap.set(x: 63, y: 63)
        let shard = ExplorationShard(
            sourceID: "day-2026-09-27",
            revision: 4,
            logicalStart: Date(timeIntervalSince1970: 1_000),
            logicalEnd: Date(timeIntervalSince1970: 2_000),
            blocks: [ExplorationShardBlock(id: FogBlockID(x: 10, y: 11), layers: [
                ExplorationLayerBitmap(layer: .visits, bitmap: bitmap),
                ExplorationLayerBitmap(layer: .ground, bitmap: bitmap)
            ])]
        )
        let first = try ExplorationShardCodec.encode(shard)
        let second = try ExplorationShardCodec.encode(shard)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try ExplorationShardCodec.decode(first), shard)

        var truncated = first
        truncated.removeLast()
        XCTAssertThrowsError(try ExplorationShardCodec.decode(truncated))
        var corrupt = first
        corrupt[corrupt.startIndex + 3] ^= 0xff
        XCTAssertThrowsError(try ExplorationShardCodec.decode(corrupt)) { error in
            XCTAssertEqual(error as? ExplorationShardError, .invalidChecksum)
        }
    }

    func testPreparationStatisticsProjection() {
        var checkpoint = ExplorationPreparationCheckpoint()
        checkpoint.startedAt = Date(timeIntervalSince1970: 0)
        checkpoint.totalDayCount = 100
        checkpoint.processedDayCount = 25
        checkpoint.readiness = .partiallyReady

        let now = Date(timeIntervalSince1970: 3_600)
        let statistics = ExplorationPreparationStatistics(checkpoint: checkpoint, now: now)

        XCTAssertEqual(statistics.remainingDayCount, 75)
        XCTAssertEqual(statistics.progressFraction, 0.25)
        XCTAssertEqual(statistics.averageDaysPerHour, 25)
        XCTAssertEqual(statistics.estimatedCompletionDate, Date(timeIntervalSince1970: 14_400))
    }

    func testWorkQueuePrioritizesImportsAndRecoversExpiredLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = ExplorationWorkQueue(rootURL: root)
        let now = Date(timeIntervalSince1970: 10_000)
        try await queue.enqueue(dayKeys: ["2020-01-01"], lane: .historical)
        try await queue.enqueue(dayKeys: ["2026-09-27"], lane: .importedHistory)

        let first = try await queue.claim(maximum: 1, leaseDuration: 1, now: now)
        XCTAssertEqual(first.first?.dayKey, "2026-09-27")
        let recovered = try await queue.recoverExpired(now: now.addingTimeInterval(2))
        XCTAssertEqual(recovered, 1)
        let retry = try await queue.claim(maximum: 1, now: now.addingTimeInterval(2))
        XCTAssertEqual(retry.first?.dayKey, "2026-09-27")
        try await queue.complete(retry[0].id)
        let historical = try await queue.claim(maximum: 1, now: now.addingTimeInterval(3))
        XCTAssertEqual(historical.first?.dayKey, "2020-01-01")
    }

    func testWorkQueueSnapshotReclaimsExpiredLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = ExplorationWorkQueue(rootURL: root)
        let now = Date(timeIntervalSince1970: 20_000)

        try await queue.enqueue(dayKeys: ["2026-09-28"], lane: .historical)
        _ = try await queue.claim(maximum: 1, leaseDuration: 1, now: now)

        let snapshot = try await queue.snapshot(now: now.addingTimeInterval(2))
        XCTAssertEqual(snapshot.queuedCount, 1)
        XCTAssertEqual(snapshot.processingCount, 0)
        XCTAssertEqual(snapshot.staleProcessingCount, 0)
    }

    func testDerivedStatisticsAreLatitudeAwareAndRebuildable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var bitmap = try FogBitmapBlock()
        bitmap.set(x: 0, y: 0)
        let shard = ExplorationShard(
            sourceID: "stats",
            revision: 1,
            logicalStart: Date(timeIntervalSince1970: 1),
            logicalEnd: Date(timeIntervalSince1970: 2),
            blocks: [ExplorationShardBlock(id: FogBlockID(x: 34_875, y: 22_743), layers: [
                ExplorationLayerBitmap(layer: .ground, bitmap: bitmap)
            ])]
        )
        try await ExplorationShardFileStore(rootURL: root).write(shard)
        let incrementalPresenceStore = ExplorationCountryPresenceIndexStore(rootURL: root)
        try await incrementalPresenceStore.update(with: shard)
        let incrementalDayKeys = try await incrementalPresenceStore.dayKeys(for: "DE")
        XCTAssertEqual(incrementalDayKeys, ["1970-01-01"])
        let snapshot = try await ExplorationStatisticsBuilder.rebuild(rootURL: root)
        XCTAssertEqual(snapshot.standardCellCount, 1)
        XCTAssertEqual(snapshot.sourceShardCount, 1)
        XCTAssertGreaterThan(snapshot.standardAreaSquareMeters, 0)
        XCTAssertEqual(snapshot.countryFirstEvidenceDates["DE"], Date(timeIntervalSince1970: 1))
        XCTAssertEqual(snapshot.countryLastEvidenceDates["DE"], Date(timeIntervalSince1970: 2))
        XCTAssertEqual(snapshot.regionCountryIDs.values.first, "DE")
        let stored = try await ExplorationStatisticsStore(rootURL: root).load()
        XCTAssertEqual(stored, snapshot)
        let presence = try await ExplorationCountryPresenceIndexStore(rootURL: root).load()
        XCTAssertEqual(presence?.entries.count, 1)
        XCTAssertEqual(presence?.entries.first?.countryCellCounts["DE"], 1)

        let presenceStore = ExplorationCountryPresenceIndexStore(rootURL: root)
        let summaries = try await presenceStore.countrySummaries()
        XCTAssertEqual(summaries.map(\.countryID), ["DE"])
        XCTAssertEqual(summaries.first?.matchingDayCount, 1)
        let dayKeys = try await presenceStore.dayKeys(for: "DE")
        XCTAssertEqual(dayKeys, ["1970-01-01"])
        let dayPresence = try await presenceStore.presence(for: "DE", dayKey: "1970-01-01")
        XCTAssertEqual(dayPresence?.countryCellCounts["DE"], 1)
    }

    func testRenderHierarchyKeepsFlightSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var ground = try FogBitmapBlock(); ground.set(x: 0, y: 0)
        var visit = try FogBitmapBlock(); visit.set(x: 0, y: 0)
        var flight = try FogBitmapBlock(); flight.set(x: 1, y: 0)
        let shard = ExplorationShard(sourceID: "render", revision: 1, blocks: [
            ExplorationShardBlock(id: FogBlockID(x: 3, y: 4), layers: [
                ExplorationLayerBitmap(layer: .ground, bitmap: ground),
                ExplorationLayerBitmap(layer: .visits, bitmap: visit),
                ExplorationLayerBitmap(layer: .flight, bitmap: flight)
            ])
        ])
        try await ExplorationShardFileStore(rootURL: root).write(shard)
        let hierarchy = ExplorationRenderHierarchy(rootURL: root)
        try await hierarchy.rebuildAll()
        let tile = try await hierarchy.read(ExplorationRenderTileID(level: 0, x: 3, y: 4))
        XCTAssertEqual(tile?.standardCellCount, 1)
        XCTAssertEqual(tile?.flightCellCount, 1)
    }

    func testRenderTileCacheIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var bitmap = try FogBitmapBlock(); bitmap.set(x: 0, y: 0)
        let blocks = [
            ExplorationShardBlock(id: FogBlockID(x: 1, y: 1), layers: [ExplorationLayerBitmap(layer: .ground, bitmap: bitmap)]),
            ExplorationShardBlock(id: FogBlockID(x: 100, y: 100), layers: [ExplorationLayerBitmap(layer: .ground, bitmap: bitmap)])
        ]
        try await ExplorationShardFileStore(rootURL: root).write(ExplorationShard(sourceID: "cache", revision: 1, blocks: blocks))
        let hierarchy = ExplorationRenderHierarchy(rootURL: root)
        try await hierarchy.rebuildAll()
        let ids = try await hierarchy.tileIDs(level: 0)
        XCTAssertGreaterThanOrEqual(ids.count, 2)
        let cache = ExplorationRenderTileCache(hierarchy: hierarchy, capacity: 1)
        _ = try await cache.read(ids[0])
        _ = try await cache.read(ids[1])
        let count = await cache.count
        XCTAssertEqual(count, 1)
    }

    func testSourceShardStorageBenchmarkForLargeCellCounts() throws {
        func encodedSize(for cellCount: Int) throws -> Int {
            let cellsPerBlock = FogBitmapBlock.width * FogBitmapBlock.width
            let blockCount = Int(ceil(Double(cellCount) / Double(cellsPerBlock)))
            var blocks: [ExplorationShardBlock] = []
            blocks.reserveCapacity(blockCount)
            var remaining = cellCount
            for index in 0..<blockCount {
                var bitmap = try FogBitmapBlock()
                for bit in 0..<min(cellsPerBlock, remaining) {
                    bitmap.set(x: bit % FogBitmapBlock.width, y: bit / FogBitmapBlock.width)
                }
                blocks.append(ExplorationShardBlock(
                    id: FogBlockID(x: UInt32(index % 128), y: UInt32(index / 128)),
                    layers: [ExplorationLayerBitmap(layer: .ground, bitmap: bitmap)]
                ))
                remaining -= min(cellsPerBlock, remaining)
            }
            return try ExplorationShardCodec.encode(ExplorationShard(sourceID: "benchmark-\(cellCount)", revision: 1, blocks: blocks)).count
        }

        let size100k = try encodedSize(for: 100_000)
        let size1m = try encodedSize(for: 1_000_000)
        let size10m = try encodedSize(for: 10_000_000)
        print("Exploration shard storage: 100k=\(size100k) bytes, 1m=\(size1m) bytes, 10m=\(size10m) bytes")
        XCTAssertLessThan(size100k, size1m)
        XCTAssertLessThan(size1m, size10m)
        XCTAssertLessThan(size10m, 2_000_000)
    }

    func testOfflineCountryResolverUsesVendoredBoundaries() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Moves/ExplorationCountryBoundaries.json"))
        let resolver = try ExplorationCountryResolver(data: data)
        XCTAssertEqual(resolver.country(at: CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755))?.id, "DE")
        XCTAssertEqual(resolver.country(at: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))?.id, "FR")
        XCTAssertNil(resolver.country(at: CLLocationCoordinate2D(latitude: 0, longitude: 0)))
    }

    func testCountryCellAttributionUsesCanonicalPolygonAreaAndDeterministicTieBreak() throws {
        let cell = FogCell(coordinate: FogRasterCoordinate(x: 2_097_152, y: 2_097_152))
        let bounds = try FogRasterV1.geographicBounds(for: cell)
        let midpoint = (bounds.west + bounds.east) / 2
        func polygon(west: Double, east: Double) -> [[[[Double]]]] {
            [[[
                [west, -1], [east, -1], [east, 1], [west, 1], [west, -1]
            ]]]
        }
        let object: [String: Any] = [
            "version": 1,
            "source": "synthetic-border",
            "countries": [
                ["id": "AA", "name": "A", "polygons": polygon(west: -1, east: midpoint)],
                ["id": "BB", "name": "B", "polygons": polygon(west: midpoint, east: 1)]
            ]
        ]
        let resolver = try ExplorationCountryResolver(data: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try resolver.country(for: cell, sampleGrid: 1)?.id, "AA")
    }

    func testOfflineAdministrativeResolverUsesVendoredBoundaries() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Moves/ExplorationAdministrativeBoundaries.json"))
        let resolver = try ExplorationAdministrativeRegionResolver(data: data)
        XCTAssertEqual(resolver.region(at: CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755))?.id, "DE-BY")
        XCTAssertEqual(resolver.region(at: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))?.countryID, "FR")
        XCTAssertFalse(resolver.availableRegions.isEmpty)
    }

    func testManualTravelEvidenceFlowsIntoPassportAndStatistics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let record = ExplorationManualTravelEvidence(
            countryID: "DE",
            countryName: "Germany",
            status: .lived,
            date: Date(timeIntervalSince1970: 123),
            note: "Home"
        )
        try await ExplorationTravelEvidenceStore(rootURL: root).upsert(record)
        let snapshot = try await ExplorationStatisticsBuilder.rebuild(rootURL: root)

        XCTAssertEqual(snapshot.countryTravelStatuses["DE"], .lived)
        XCTAssertEqual(snapshot.countryProvenance["DE"], [.manual])
        XCTAssertEqual(snapshot.manualTravelEvidenceCount, 1)
        let stamp = try XCTUnwrap(ExplorationPassportBuilder.stamps(snapshot).first)
        XCTAssertEqual(stamp.countryID, "DE")
        XCTAssertTrue(stamp.isManualOnly)
        XCTAssertEqual(stamp.status, .lived)
        XCTAssertEqual(stamp.provenance, [.manual])
    }

    func testPassportRecipesAreDeterministicAndVaryByCountry() throws {
        let first = ExplorationPassportBuilder.stamps(
            countryCellCounts: ["DE": 1, "FR": 1],
            countryNames: ["DE": "Germany", "FR": "France"],
            countryAreaSquareMeters: [:],
            firstEvidenceDate: nil,
            lastEvidenceDate: nil
        )
        let second = ExplorationPassportBuilder.stamps(
            countryCellCounts: ["DE": 1, "FR": 1],
            countryNames: ["DE": "Germany", "FR": "France"],
            countryAreaSquareMeters: [:],
            firstEvidenceDate: nil,
            lastEvidenceDate: nil
        )
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first[0].recipe, first[1].recipe)
    }

    func testAchievementStatePreservesUnlockDate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstDate = Date(timeIntervalSince1970: 456)
        let first = ExplorationDerivedStatistics(
            schemaVersion: 1, rasterVersion: .fogRasterV1, generatedAt: firstDate,
            includeFlight: false, sourceShardCount: 1, canonicalBlockCount: 1,
            baseTileCount: 1, layerCellCounts: [.ground: 1], standardCellCount: 1,
            standardAreaSquareMeters: 1, flightAreaSquareMeters: 0, datedSourceCount: 1,
            firstEvidenceDate: firstDate, lastEvidenceDate: firstDate
        )
        let store = ExplorationAchievementStore(rootURL: root)
        let initial = try await store.refresh(from: first)
        XCTAssertEqual(initial.achievements.first(where: { $0.id == .firstEvidence })?.unlockedAt, firstDate)

        let later = ExplorationDerivedStatistics(
            schemaVersion: 1, rasterVersion: .fogRasterV1, generatedAt: Date(timeIntervalSince1970: 789),
            includeFlight: false, sourceShardCount: 2, canonicalBlockCount: 2,
            baseTileCount: 2, layerCellCounts: [.ground: 2], standardCellCount: 2,
            standardAreaSquareMeters: 2, flightAreaSquareMeters: 0, datedSourceCount: 2,
            firstEvidenceDate: Date(timeIntervalSince1970: 1), lastEvidenceDate: Date(timeIntervalSince1970: 789)
        )
        let refreshed = try await store.refresh(from: later)
        XCTAssertEqual(refreshed.achievements.first(where: { $0.id == .firstEvidence })?.unlockedAt, firstDate)
    }

    func testPreparationResetDeletesDerivedDataButNotOutsideHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ExplorationShardFileStore(rootURL: root)
        let checkpointStore = ExplorationPreparationCheckpointStore(rootURL: root)
        var checkpoint = ExplorationPreparationCheckpoint()
        checkpoint.processedDayCount = 3
        try await checkpointStore.save(checkpoint)

        try await ExplorationTravelEvidenceStore(rootURL: root).upsert(
            ExplorationManualTravelEvidence(countryID: "DE", countryName: "Germany", status: .visited)
        )

        var bitmap = try FogBitmapBlock()
        bitmap.set(x: 1, y: 1)
        try await store.write(
            ExplorationShard(
                sourceID: "day:2026-09-27",
                revision: 1,
                blocks: [
                    ExplorationShardBlock(
                        id: FogBlockID(x: 1, y: 2),
                        layers: [ExplorationLayerBitmap(layer: .ground, bitmap: bitmap)]
                    )
                ]
            )
        )
        let blockDirectory = root.appendingPathComponent("v1/blocks", isDirectory: true)
        try FileManager.default.createDirectory(at: blockDirectory, withIntermediateDirectories: true)
        try Data("derived".utf8).write(to: blockDirectory.appendingPathComponent("1-2.block"))

        try await checkpointStore.removeAllPreparationData()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v1/sources").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blockDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v1/preparation.json").path))
        let remainingShards = try await store.allShards()
        XCTAssertTrue(remainingShards.isEmpty)
        let remainingTravelEvidence = try await ExplorationTravelEvidenceStore(rootURL: root).load()
        XCTAssertEqual(remainingTravelEvidence.count, 1)
    }

#if DEBUG
    func testFogNativeBitmapTileDecodesCanonicalBlock() throws {
        let headerSize = 128 * 128 * 2
        let blockSize = FogBitmapBlock.byteCount + 3
        var inflated = Data(repeating: 0, count: headerSize + blockSize)
        inflated[0] = 1
        inflated[headerSize] = 0x80
        inflated[headerSize + FogBitmapBlock.byteCount + 2] = 3

        let decoded = try FogArchiveReader.decodeInflatedTile(
            filename: "81dclhwjxd",
            data: inflated
        )

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].tileID, 1_234)
        XCTAssertEqual(decoded[0].localX, 0)
        XCTAssertEqual(decoded[0].localY, 0)
        XCTAssertEqual(decoded[0].bitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }, 1)
        XCTAssertTrue(decoded[0].bitmap.contains(x: 0, y: 0))
    }

    func testFogSyncExportAndImportRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ExplorationShardFileStore(rootURL: root)
        var bitmap = try FogBitmapBlock()
        bitmap.set(x: 0, y: 0)
        try await store.write(
            ExplorationShard(
                sourceID: "roundtrip",
                revision: 1,
                blocks: [
                    ExplorationShardBlock(
                        id: FogBlockID(x: 210 * 128, y: 2 * 128),
                        layers: [ExplorationLayerBitmap(layer: .ground, bitmap: bitmap)]
                    )
                ]
            )
        )

        let exported = try await FogOfWorldDebugImporter.exportSyncArchive(rootURL: root)
        let archiveURL = root.appendingPathComponent("roundtrip.zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try exported.data.write(to: archiveURL)

        let importedRoot = root.appendingPathComponent("imported")
        let imported = try await FogOfWorldDebugImporter.importArchive(
            at: archiveURL,
            rootURL: importedRoot
        )
        XCTAssertEqual(imported.archiveKind, "Fog sync archive")
        XCTAssertEqual(imported.tileCount, 1)
        XCTAssertEqual(imported.blockCount, 1)
        XCTAssertEqual(imported.revealedCellCount, 1)

        let checkpointDirectory = importedRoot.appendingPathComponent("v1/imports", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointDirectory.path))
        let repeated = try await FogOfWorldDebugImporter.importArchive(
            at: archiveURL,
            rootURL: importedRoot
        )
        XCTAssertEqual(repeated.tileCount, 0)
        XCTAssertEqual(repeated.blockCount, 0)

        let fwss = try await FogOfWorldDebugImporter.exportFWSSArchive(rootURL: root)
        let fwssURL = root.appendingPathComponent("roundtrip.fwss")
        try fwss.data.write(to: fwssURL)
        let importedFWSS = try await FogOfWorldDebugImporter.importArchive(
            at: fwssURL,
            rootURL: root.appendingPathComponent("imported-fwss")
        )
        XCTAssertEqual(importedFWSS.archiveKind, "Fog FWSS archive")
        XCTAssertEqual(importedFWSS.tileCount, 1)
        XCTAssertEqual(importedFWSS.blockCount, 1)
    }
#endif

    func testSourceReplacementPreservesOverlappingContributionAndAtomicity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ExplorationShardFileStore(rootURL: root.appendingPathComponent("sources"))
        let cache = ExplorationMergedCache(rootURL: root.appendingPathComponent("cache"), shardStore: sources)
        let id = FogBlockID(x: 1, y: 2)

        var a = try FogBitmapBlock(); a.set(x: 1, y: 1); a.set(x: 3, y: 3)
        var b = try FogBitmapBlock(); b.set(x: 3, y: 3); b.set(x: 5, y: 5)
        try await cache.mergeShard(ExplorationShard(sourceID: "a", revision: 1, blocks: [ExplorationShardBlock(id: id, layers: [ExplorationLayerBitmap(layer: .ground, bitmap: a)])]))
        try await cache.mergeShard(ExplorationShard(sourceID: "b", revision: 1, blocks: [ExplorationShardBlock(id: id, layers: [ExplorationLayerBitmap(layer: .ground, bitmap: b)])]))
        let firstMerged = try await cache.readBlock(id)
        var merged = try XCTUnwrap(firstMerged)
        XCTAssertTrue(merged.bitmap(for: .ground)!.isSet(x: 1, y: 1))
        XCTAssertTrue(merged.bitmap(for: .ground)!.isSet(x: 5, y: 5))

        var a2 = try FogBitmapBlock(); a2.set(x: 1, y: 1)
        try await cache.replaceShard(ExplorationShard(sourceID: "a", revision: 2, blocks: [ExplorationShardBlock(id: id, layers: [ExplorationLayerBitmap(layer: .ground, bitmap: a2)])]))
        let secondMerged = try await cache.readBlock(id)
        merged = try XCTUnwrap(secondMerged)
        XCTAssertTrue(merged.bitmap(for: .ground)!.isSet(x: 1, y: 1))
        XCTAssertTrue(merged.bitmap(for: .ground)!.isSet(x: 3, y: 3))
        XCTAssertTrue(merged.bitmap(for: .ground)!.isSet(x: 5, y: 5))

        try await cache.removeShard(sourceID: "b")
        let thirdMerged = try await cache.readBlock(id)
        merged = try XCTUnwrap(thirdMerged)
        XCTAssertTrue(merged.bitmap(for: .ground)!.isSet(x: 1, y: 1))
        XCTAssertFalse(merged.bitmap(for: .ground)!.isSet(x: 3, y: 3))

        let oldValue = try await sources.read(sourceID: "a")
        let old = try XCTUnwrap(oldValue)
        do {
            try await sources.write(old, failBeforeReplacement: true)
            XCTFail("expected the injected pre-replacement failure")
        } catch {
            // The old shard must remain the valid file after a failed replacement.
        }
        let restored = try await sources.read(sourceID: "a")
        XCTAssertEqual(restored, old)
    }

    func testRemoteRevisionOrderingAndTombstoneCannotResurrectCoverage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ExplorationShardFileStore(rootURL: root.appendingPathComponent("sources"))
        let cache = ExplorationMergedCache(rootURL: root.appendingPathComponent("cache"), shardStore: sources)
        let id = FogBlockID(x: 7, y: 8)

        var current = try FogBitmapBlock()
        current.set(x: 2, y: 2)
        let revision2 = ExplorationShard(sourceID: "remote", revision: 2, blocks: [
            ExplorationShardBlock(id: id, layers: [ExplorationLayerBitmap(layer: .ground, bitmap: current)])
        ])
        try await cache.mergeShard(revision2)

        var stale = try FogBitmapBlock()
        stale.set(x: 9, y: 9)
        let revision1 = ExplorationShard(sourceID: "remote", revision: 1, blocks: [
            ExplorationShardBlock(id: id, layers: [ExplorationLayerBitmap(layer: .ground, bitmap: stale)])
        ])
        try await cache.mergeShard(revision1)
        let afterStaleValue = try await cache.readBlock(id)
        let afterStale = try XCTUnwrap(afterStaleValue)
        XCTAssertTrue(afterStale.bitmap(for: .ground)!.isSet(x: 2, y: 2))
        XCTAssertFalse(afterStale.bitmap(for: .ground)!.isSet(x: 9, y: 9))

        // An empty replacement is the transport-safe tombstone. A later
        // delivery of the old revision must not bring its cells back.
        try await cache.mergeShard(ExplorationShard(sourceID: "remote", revision: 3, blocks: []))
        let afterTombstone = try await cache.readBlock(id)
        XCTAssertNil(afterTombstone)
        try await cache.mergeShard(revision2)
        let afterResurrectionAttempt = try await cache.readBlock(id)
        XCTAssertNil(afterResurrectionAttempt)
    }

    func testFlightFingerprintBoundsRouteAndResolvesMultipleNearbyAirports() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = FlightFingerprint(
            moveID: UUID(),
            start: start,
            end: start.addingTimeInterval(7_200),
            startCoordinate: FlightCoordinate(latitude: 53.63, longitude: 9.99),
            endCoordinate: FlightCoordinate(latitude: 48.35, longitude: 11.79),
            sampledRoute: (0..<200).map { FlightCoordinate(latitude: 53.63 - Double($0) * 0.026, longitude: 9.99 + Double($0) * 0.009) },
            distanceMeters: 760_000
        )

        XCTAssertEqual(fingerprint.sampledRoute.count, 24)
        let resolution = FlightAirportResolver.resolve(
            fingerprint: fingerprint,
            database: BundledAirportDatabase.make()
        )
        XCTAssertEqual(resolution.originCandidates.first?.iataCode, "HAM")
        XCTAssertEqual(resolution.destinationCandidates.first?.iataCode, "MUC")
    }

    func testFlightMatchingRanksDelayedActualTimeAndCachesResponse() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(7_200)
        let fingerprint = FlightFingerprint(
            moveID: UUID(),
            start: start,
            end: end,
            startCoordinate: FlightCoordinate(latitude: 53.6304, longitude: 9.9882),
            endCoordinate: FlightCoordinate(latitude: 48.3538, longitude: 11.7861),
            sampledRoute: [
                FlightCoordinate(latitude: 53.6304, longitude: 9.9882),
                FlightCoordinate(latitude: 50.5, longitude: 10.8),
                FlightCoordinate(latitude: 48.3538, longitude: 11.7861),
            ],
            distanceMeters: 760_000
        )
        let database = BundledAirportDatabase.make()
        let resolution = FlightAirportResolver.resolve(fingerprint: fingerprint, database: database)
        let origin = try XCTUnwrap(resolution.originCandidates.first)
        let destination = try XCTUnwrap(resolution.destinationCandidates.first)

        func candidate(id: String, scheduledDeparture: Date, actualDeparture: Date, actualArrival: Date) -> HistoricalFlightCandidate {
            HistoricalFlightCandidate(
                id: id,
                airlineName: "Example Air",
                airlineIATA: "EX",
                airlineICAO: "EXA",
                marketedFlightNumber: id,
                callsign: "EXA\(id.dropFirst())",
                origin: origin,
                destination: destination,
                scheduledDeparture: scheduledDeparture,
                actualDeparture: actualDeparture,
                scheduledArrival: scheduledDeparture.addingTimeInterval(7_200),
                actualArrival: actualArrival,
                aircraftRegistration: nil,
                aircraftType: "A320",
                historicalTrack: fingerprint.sampledRoute,
                routeDistanceMeters: 760_000,
                sourceIdentifier: "fixture"
            )
        }

        let delayed = candidate(
            id: "EX2055",
            scheduledDeparture: start.addingTimeInterval(-3_600),
            actualDeparture: start,
            actualArrival: end
        )
        let scheduledOnly = candidate(
            id: "EX2056",
            scheduledDeparture: start,
            actualDeparture: start.addingTimeInterval(3_600),
            actualArrival: end.addingTimeInterval(3_600)
        )
        let service = FlightMatchingService(
            database: database,
            provider: InMemoryHistoricalFlightProvider(candidates: [delayed, scheduledOnly])
        )

        let first = try await service.match(fingerprint)
        let second = try await service.match(fingerprint)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.bestMatch?.candidate.id, "EX2055")
        XCTAssertTrue(first.bestMatch?.evidence.contains(where: { $0.signal == .trajectory }) == true)
    }

    func testProviderSuggestionCanBeConfirmedButNeverOverwritesUserMetadata() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let origin = AirportRecord(icaoCode: "EDDH", iataCode: "HAM", name: "Hamburg", coordinate: FlightCoordinate(latitude: 53.63, longitude: 9.99), municipality: "Hamburg", countryCode: "DE", airportType: .largeAirport)
        let destination = AirportRecord(icaoCode: "EDDM", iataCode: "MUC", name: "Munich", coordinate: FlightCoordinate(latitude: 48.35, longitude: 11.79), municipality: "Munich", countryCode: "DE", airportType: .largeAirport)
        let candidate = HistoricalFlightCandidate(
            id: "fixture-2055",
            airlineName: "Example Air",
            airlineIATA: "EX",
            airlineICAO: "EXA",
            marketedFlightNumber: "2055",
            callsign: "EXA2055",
            origin: AirportCandidate(airport: origin, distanceMeters: 100),
            destination: AirportCandidate(airport: destination, distanceMeters: 100),
            scheduledDeparture: start,
            actualDeparture: start,
            scheduledArrival: start.addingTimeInterval(7_200),
            actualArrival: start.addingTimeInterval(7_200),
            aircraftRegistration: nil,
            aircraftType: "A320",
            historicalTrack: [],
            routeDistanceMeters: 760_000,
            sourceIdentifier: "fixture"
        )
        let fingerprint = FlightFingerprint(moveID: UUID(), start: start, end: start.addingTimeInterval(7_200), startCoordinate: origin.coordinate, endCoordinate: destination.coordinate, sampledRoute: [], distanceMeters: 760_000)
        let match = FlightMatchRanker.rank(fingerprint: fingerprint, candidate: candidate)
        let move = MoveSegment(dedupeKey: "flight", startDate: start, endDate: start.addingTimeInterval(7_200), transportMode: .plane, distanceMeters: 760_000, stepCount: nil)

        XCTAssertTrue(move.storeProviderSuggestion(match))
        XCTAssertEqual(move.flightMetadata?.provenance, .providerSuggested)
        XCTAssertTrue(move.confirmFlightMatch(match))
        XCTAssertEqual(move.flightMetadata?.provenance, .userConfirmed)

        let manual = FlightMetadata(airlineName: "Manual Air", marketedFlightNumber: "MAN1", originIATA: "HAM", destinationIATA: "MUC", provenance: .userEntered)
        XCTAssertTrue(move.setUserEnteredFlightMetadata(manual))
        XCTAssertFalse(move.storeProviderSuggestion(match))
        XCTAssertFalse(move.confirmFlightMatch(match))
        XCTAssertEqual(move.flightMetadata?.airlineName, "Manual Air")

        move.markFlightMatchStale()
        XCTAssertFalse(move.flightMetadata?.isStale ?? true)
    }
}
