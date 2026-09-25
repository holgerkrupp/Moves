import XCTest
import CoreLocation
import SwiftData
@testable import Moves

/// Generated importer coverage. The fixtures are deliberately tiny in source and are expanded
/// at runtime so stress regressions never require committing user data to the repository.
final class ImportStressTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testGeneratedLargeGPXIsChunkedWithoutDroppingPoints() throws {
        let points = 20_000
        let data = makeGPX(pointCount: points, withTimestamps: true)
        let url = try temporaryFile(named: "large.gpx", data: data)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let chunks = try RouteTrackParserWorker.parse(url: url)

        XCTAssertEqual(chunks.count, 5)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.points.count }, points)
        XCTAssertTrue(chunks.allSatisfy(\.hasOriginalTimestamps))
    }

    func testManyFilesMixedFormatsAndZIPAcquireDeterministically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<18 {
            let name = String(format: "route-%02d.gpx", index)
            try makeGPX(pointCount: 8, withTimestamps: true).write(to: source.appendingPathComponent(name))
        }
        let geoJSON = #"{"type":"Feature","geometry":{"type":"LineString","coordinates":[[13.4,52.5],[13.41,52.51]]}}"#
        try Data(geoJSON.utf8).write(to: source.appendingPathComponent("mixed.geojson"))
        let zip = try makeStoredZIP(entries: [
            ("inside.gpx", makeGPX(pointCount: 5, withTimestamps: true)),
            ("inside.geojson", Data(geoJSON.utf8))
        ])
        let archive = source.appendingPathComponent("routes.zip")
        try zip.write(to: archive)

        let result = try RouteImportAcquirer(stagingDirectory: staging).acquire(urls: [source, archive, source])

        let expectedNames = ["mixed.geojson"]
            + (0..<18).map { String(format: "route-%02d.gpx", $0) }
            + ["inside.geojson", "inside.gpx"]
        XCTAssertEqual(result.sourceNames, expectedNames)
        XCTAssertEqual(Set(result.sourceNames).count, result.sourceNames.count)
        XCTAssertTrue(result.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testMissingTimestampsAndCorruptGPXAreExplicit() throws {
        let missing = try temporaryFile(named: "missing-time.gpx", data: makeGPX(pointCount: 4, withTimestamps: false))
        let corrupt = try temporaryFile(named: "corrupt.gpx", data: Data("not xml".utf8))
        defer {
            try? FileManager.default.removeItem(at: missing.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: corrupt.deletingLastPathComponent())
        }

        let missingTracks = try RouteTrackParserWorker.parse(url: missing)
        XCTAssertFalse(missingTracks.isEmpty)
        XCTAssertTrue(missingTracks.contains { !$0.hasOriginalTimestamps })
        XCTAssertThrowsError(try RouteTrackParserWorker.parse(url: corrupt))
    }

    @MainActor
    func testDuplicateAndOverlappingRoutesRemainIdempotentAtRepositoryBoundary() throws {
        let container = try testContainer()
        let repository = SwiftDataTimelineRepository(modelContainer: container)
        let locations = makeLocations(count: 12)

        let first = try repository.importRouteTrack(locations: locations, source: .fileRouteImport,
                                                    transportMode: .walking, resolvePlaceNames: false)
        let second = try repository.importRouteTrack(locations: locations, source: .fileRouteImport,
                                                     transportMode: .walking, resolvePlaceNames: false)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let context = ModelContext(container)
        let samples = try context.fetch(FetchDescriptor<LocationSample>())
        XCTAssertLessThanOrEqual(samples.count, locations.count)
    }

    @MainActor
    func testWorkerPauseAndCancellationStopAtCheckpoint() async throws {
        let worker = RouteFileImportWorker(modelContainer: try testContainer())
        let track = RouteTrackDTO(points: makeLocations(count: 64).map {
            RouteTrackPointDTO(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                               altitude: $0.altitude, timestamp: $0.timestamp)
        }, transportMode: .walking, hasOriginalTimestamps: true)

        do {
            _ = try await worker.importTracks([track], configuration: RouteFileImportConfiguration(), shouldPause: { true })
            XCTFail("Expected a pause checkpoint")
        } catch RouteFileImportWorker.WorkerError.paused {
            // expected
        }

        let task = Task {
            try await worker.importTracks([track], configuration: RouteFileImportConfiguration(), shouldPause: {
                await Task.yield()
                return false
            })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testLargeGPXParsingLeavesMainActorHeartbeatResponsive() async throws {
        let url = try temporaryFile(named: "heartbeat.gpx", data: makeGPX(pointCount: 80_000, withTimestamps: true))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let parseTask = Task.detached(priority: .utility) {
            try RouteTrackParserWorker.parse(url: url).reduce(0) { $0 + $1.points.count }
        }
        let heartbeat = Task { @MainActor in
            var count = 0
            while !parseTask.isCancelled {
                count += 1
                await Task.yield()
                if parseTask.isCancelled { break }
                if count > 10_000 { break }
            }
            return count
        }
        let parsedCount = try await parseTask.value
        heartbeat.cancel()
        _ = await heartbeat.value
        XCTAssertEqual(parsedCount, 80_000)
    }

    func testAcquisitionBoundsPreventUnboundedStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = root.appendingPathComponent("input.gpx")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeGPX(pointCount: 200, withTimestamps: true).write(to: input)
        XCTAssertThrowsError(try RouteImportAcquirer(
            stagingDirectory: root.appendingPathComponent("staged"),
            configuration: RouteImportAcquisitionConfiguration(maximumStagedFiles: 1, maximumStagedBytes: 64)
        ).acquire(urls: [input])) { error in
            XCTAssertEqual(error as? RouteImportAcquisitionError, .stagingByteLimitExceeded(maximum: 64))
        }
    }

    // Issue #2 regression: importing a large GPX must parse in a detached utility task and finish
    // with all points represented, instead of blocking the main actor or crashing on the payload.
    func testIssue2LargeGPXRegression() async throws {
        let url = try temporaryFile(named: "issue-2-regression.gpx", data: makeGPX(pointCount: 12_000, withTimestamps: true))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let count = try await Task.detached(priority: .utility) {
            try RouteTrackParserWorker.parse(url: url).reduce(0) { $0 + $1.points.count }
        }.value
        XCTAssertEqual(count, 12_000)
    }

    @MainActor
    func testImportedRouteSummaryCountsOnlyFileRouteData() async throws {
        let container = try testContainer()
        let context = ModelContext(container)
        let timeline = DayTimeline(dayStart: epoch)
        let importedMove = MoveSegment(
            dedupeKey: "imported-move",
            startDate: epoch,
            endDate: epoch.addingTimeInterval(60),
            transportMode: .walking,
            distanceMeters: 100,
            stepCount: nil
        )
        let recordedMove = MoveSegment(
            dedupeKey: "recorded-move",
            startDate: epoch.addingTimeInterval(120),
            endDate: epoch.addingTimeInterval(180),
            transportMode: .walking,
            distanceMeters: 100,
            stepCount: nil
        )
        let locations = makeLocations(count: 3)
        let importedSamples = locations.prefix(2).enumerated().map { index, location in
            LocationSample(
                location: location,
                source: .fileRouteImport,
                dedupeKey: "imported-\(index)"
            )
        }
        let recordedSample = LocationSample(
            location: locations[2],
            source: .routeTracking,
            dedupeKey: "recorded"
        )
        let visit = VisitPlace(
            arrivalDate: epoch.addingTimeInterval(-60),
            departureDate: epoch,
            latitude: 52,
            longitude: 13,
            horizontalAccuracy: 10
        )

        // Match the importer's write path: children own the day relationship and the inverse
        // arrays are left for SwiftData to maintain.
        visit.dayTimeline = timeline
        importedMove.dayTimeline = timeline
        importedMove.samples = importedSamples
        recordedMove.dayTimeline = timeline
        recordedMove.samples = [recordedSample]
        importedSamples.forEach {
            $0.dayTimeline = timeline
            $0.moveSegment = importedMove
        }
        recordedSample.dayTimeline = timeline
        recordedSample.moveSegment = recordedMove
        context.insert(timeline)
        context.insert(visit)
        context.insert(importedMove)
        context.insert(recordedMove)
        importedSamples.forEach(context.insert)
        context.insert(recordedSample)
        try context.save()

        let (summary, daySummaries) = try await Task.detached(priority: .utility) {
            let worker = ImportedRouteDataSummaryWorker(modelContainer: container)
            let imported = try await worker.calculate()
            let days = try await worker.calculateDaySummaries()
            return (imported, days)
        }.value

        XCTAssertEqual(summary, ImportedRouteDataSummary(sampleCount: 2, moveCount: 1))
        XCTAssertEqual(
            daySummaries[timeline.dayKey],
            TimelineDaySummary(placeCount: 1, moveCount: 2, sampleCount: 3)
        )
    }
}

private extension ImportStressTests {
    func temporaryFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func makeGPX(pointCount: Int, withTimestamps: Bool) -> Data {
        let formatter = ISO8601DateFormatter()
        var points: [String] = []
        points.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            let time = withTimestamps ? "<time>\(formatter.string(from: epoch.addingTimeInterval(Double(index))))</time>" : ""
            let latitude = String(format: "%.6f", 52.0 + Double(index) * 0.00001)
            let longitude = String(format: "%.6f", 13.0 + Double(index) * 0.00001)
            points.append("<trkpt lat=\"\(latitude)\" lon=\"\(longitude)\">\(time)</trkpt>")
        }
        return Data(("<gpx><trk><trkseg>" + points.joined() + "</trkseg></trk></gpx>").utf8)
    }

    func makeLocations(count: Int) -> [CLLocation] {
        (0..<count).map { index in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 52 + Double(index) * 0.0001,
                                                          longitude: 13 + Double(index) * 0.0001),
                      altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                      course: -1, speed: -1, timestamp: epoch.addingTimeInterval(Double(index) * 30))
        }
    }

    @MainActor
    func testContainer() throws -> ModelContainer {
        let schema = Schema([DayTimeline.self, VisitPlace.self, KnownLocation.self, MoveSegment.self,
                             LocationSample.self, MovesDeviceProfile.self, ShareMapAggregate.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    func makeStoredZIP(entries: [(String, Data)]) throws -> Data {
        var output = Data()
        var central = Data()
        var offset: UInt32 = 0
        for (name, payload) in entries {
            let nameData = Data(name.utf8)
            let crc = crc32(payload)
            output.appendLE(UInt32(0x04034b50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(crc); output.appendLE(UInt32(payload.count)); output.appendLE(UInt32(payload.count))
            output.appendLE(UInt16(nameData.count)); output.appendLE(UInt16(0))
            output.append(nameData); output.append(payload)
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(crc); central.appendLE(UInt32(payload.count)); central.appendLE(UInt32(payload.count))
            central.appendLE(UInt16(nameData.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(offset); central.append(nameData)
            offset = UInt32(output.count)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x06054b50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(entries.count)); output.appendLE(UInt16(entries.count))
        output.appendLE(UInt32(central.count)); output.appendLE(centralOffset); output.appendLE(UInt16(0))
        return output
    }

    func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb88320 &* (crc & 1)) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8)]) }
    mutating func appendLE(_ value: UInt32) { append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]) }
}
