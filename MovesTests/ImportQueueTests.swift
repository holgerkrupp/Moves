import XCTest
@testable import Moves

final class ImportQueueTests: XCTestCase {
    private func makeStore() throws -> (ImportQueueStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ImportQueueStore(fileURL: directory.appendingPathComponent("queue.json")), directory)
    }

    @MainActor
    func testQueuePersistsAndRestoresRunningJobsAsPaused() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var job = ImportJobRecord(displayName: "GPX batch", state: .importing, phase: .importing)
        job.counters.itemCount = 4
        try store.save([job])

        let restored = try store.load()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].id, job.id)
        XCTAssertEqual(restored[0].state, .paused)
    }

    @MainActor
    func testCoordinatorTransitionsAndAggregateProgress() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ImportCoordinator(store: store)
        var first = ImportJobRecord(displayName: "First")
        first.counters = ImportJobCounters(itemCount: 2, completedItemCount: 1)
        var second = ImportJobRecord(displayName: "Second")
        second.counters = ImportJobCounters(itemCount: 4, completedItemCount: 2)
        try coordinator.enqueue(first)
        try coordinator.enqueue(second)
        XCTAssertEqual(coordinator.aggregateProgress ?? -1, 0.5, accuracy: 0.001)

        try coordinator.pause(id: first.id)
        XCTAssertEqual(coordinator.jobs.first?.state, .paused)
        try coordinator.resume(id: first.id)
        XCTAssertEqual(coordinator.jobs.first?.state, .queued)
        try coordinator.cancel(id: second.id)
        XCTAssertEqual(try store.load().first(where: { $0.id == second.id })?.state, .cancelled)
    }

    @MainActor
    func testSnapshotIncludesQueueSummaryAndCounters() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ImportCoordinator(store: store)
        var job = ImportJobRecord(displayName: "Routes", state: .importing, phase: .parsing)
        job.counters = ImportJobCounters(itemCount: 4, completedItemCount: 3, routeCount: 2, sampleCount: 18)
        try coordinator.enqueue(job)

        XCTAssertEqual(coordinator.snapshot.unfinishedJobs.map(\.id), [job.id])
        XCTAssertEqual(coordinator.snapshot.aggregateProgress ?? -1, 0.75, accuracy: 0.001)
        XCTAssertEqual(coordinator.snapshot.jobs.first?.phase, .parsing)
        XCTAssertEqual(coordinator.snapshot.jobs.first?.counters.sampleCount, 18)
    }

    @MainActor
    func testRetryClearsRecoverableError() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ImportCoordinator(store: store)
        var job = ImportJobRecord(displayName: "Retry", state: .failed)
        job.lastError = ImportJobError(message: "temporary", isRecoverable: true, occurredAt: .now)
        try coordinator.enqueue(job)
        try coordinator.retry(id: job.id)
        XCTAssertEqual(coordinator.jobs[0].state, .queued)
        XCTAssertNil(coordinator.jobs[0].lastError)
    }

    func testAcquirerCopiesLocalFileIntoAppOwnedStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = root.appendingPathComponent("Application Support/Moves/RouteImport")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("route.gpx")
        try Data("<gpx/>".utf8).write(to: source)

        let result = try RouteImportAcquirer(stagingDirectory: staging).acquire(urls: [source])

        XCTAssertEqual(result.files.count, 1)
        XCTAssertNotEqual(result.files[0], source)
        XCTAssertEqual(try Data(contentsOf: result.files[0]), Data("<gpx/>".utf8))
        XCTAssertTrue(result.files[0].path.hasSuffix("-route.gpx"))
    }

    func testAcquirerEnumeratesFoldersDeterministicallyAndDeduplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("routes")
        let staging = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.gpx"))
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.gpx"))

        let result = try RouteImportAcquirer(stagingDirectory: staging).acquire(urls: [folder, folder])

        XCTAssertEqual(result.sourceNames, ["a.gpx", "b.gpx"])
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["000000-a.gpx", "000001-b.gpx"])
    }

    func testAcquirerReportsMissingSourceAsRecoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try RouteImportAcquirer(stagingDirectory: root.appendingPathComponent("staged")).acquire(
            urls: [root.appendingPathComponent("missing.gpx")]
        )) { error in
            XCTAssertEqual(error as? RouteImportAcquisitionError, .sourceUnavailable(root.appendingPathComponent("missing.gpx").path))
        }
    }

    func testAcquirerEnforcesBoundedStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("large.gpx")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 10).write(to: source)

        XCTAssertThrowsError(try RouteImportAcquirer(
            stagingDirectory: root.appendingPathComponent("staged"),
            configuration: RouteImportAcquisitionConfiguration(maximumStagedFiles: 1, maximumStagedBytes: 9)
        ).acquire(urls: [source])) { error in
            XCTAssertEqual(error as? RouteImportAcquisitionError, .stagingLimitExceeded)
        }
    }
}
