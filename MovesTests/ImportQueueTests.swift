import XCTest
import Combine
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
        XCTAssertEqual(try store.load(restoringInterruptedJobs: false)[0].state, .importing)
    }

    @MainActor
    func testCoordinatorReflectsBackgroundWorkerStoreUpdates() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ImportCoordinator(store: store)
        var job = ImportJobRecord(displayName: "route.gpx", state: .acquiring, phase: .acquiring)
        job.counters.itemCount = 1
        try coordinator.enqueue(job)

        let updated = expectation(description: "Coordinator reloads the background-worker update")
        let observation = coordinator.$snapshot
            .dropFirst()
            .sink { snapshot in
                guard snapshot.jobs.first?.state == .completed else { return }
                updated.fulfill()
            }

        try store.update(id: job.id) { storedJob in
            storedJob.state = .completed
            storedJob.phase = nil
            storedJob.counters.completedItemCount = 1
        }

        await fulfillment(of: [updated], timeout: 1)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(coordinator.jobs.first?.state, .completed)
        XCTAssertEqual(coordinator.aggregateProgress, 1)
    }

    @MainActor
    func testCoordinatorAutomaticallyRemovesFinishedImports() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ImportCoordinator(store: store)

        let removed = expectation(description: "Finished import is removed")
        let observation = coordinator.$snapshot
            .dropFirst()
            .sink { snapshot in
                guard snapshot.jobs.isEmpty else { return }
                removed.fulfill()
            }

        var completed = ImportJobRecord(displayName: "finished.gpx", state: .completed, phase: nil)
        completed.counters = ImportJobCounters(itemCount: 1, completedItemCount: 1)
        try coordinator.enqueue(completed)

        await fulfillment(of: [removed], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(try store.load(restoringInterruptedJobs: false).isEmpty)
    }

    @MainActor
    func testRemoveFinishedImportsKeepsFailedAndActiveJobs() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ImportCoordinator(store: store)
        try coordinator.enqueue(ImportJobRecord(displayName: "finished.gpx", state: .completed, phase: nil))
        try coordinator.enqueue(ImportJobRecord(displayName: "failed.gpx", state: .failed, phase: nil))
        try coordinator.enqueue(ImportJobRecord(displayName: "active.gpx", state: .importing, phase: .importing))

        XCTAssertEqual(try coordinator.removeFinishedImports(), 1)
        XCTAssertEqual(Set(coordinator.jobs.map(\.displayName)), ["failed.gpx", "active.gpx"])
    }

    func testPrioritizedJobsCapsTheVisibleQueueAndPrefersActiveWork() {
        let now = Date()
        var jobs = (0..<7).map { index in
            ImportJobRecord(
                displayName: "active-\(index).gpx",
                state: .importing,
                phase: .importing,
                updatedAt: now.addingTimeInterval(Double(index))
            )
        }
        jobs.append(ImportJobRecord(
            displayName: "finished.gpx",
            state: .completed,
            phase: nil,
            updatedAt: now.addingTimeInterval(100)
        ))

        let visible = ImportQueueSnapshot(jobs: jobs).prioritizedJobs(limit: 5)

        XCTAssertEqual(visible.count, 5)
        XCTAssertTrue(visible.allSatisfy { $0.state == .importing })
        XCTAssertEqual(visible.map(\.displayName), [
            "active-6.gpx", "active-5.gpx", "active-4.gpx", "active-3.gpx", "active-2.gpx"
        ])
    }

    func testImportJobProvidesCurrentAndUpcomingFileNames() {
        var job = ImportJobRecord(
            displayName: "Routes",
            source: ImportJobSourceMetadata(originalFileNames: ["one.gpx", "two.gpx", "three.gpx", "four.gpx"]),
            state: .importing,
            phase: .importing
        )
        job.counters = ImportJobCounters(itemCount: 4, completedItemCount: 1)

        XCTAssertEqual(job.upcomingFileNames(limit: 2), ["two.gpx", "three.gpx"])
    }

    func testImportJobEstimatesCompletionFromCompletedFiles() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var job = ImportJobRecord(
            displayName: "Routes",
            state: .importing,
            phase: .importing,
            createdAt: now.addingTimeInterval(-100)
        )
        job.counters = ImportJobCounters(itemCount: 10, completedItemCount: 2)

        let estimate = try XCTUnwrap(job.estimatedCompletionDate(at: now))

        XCTAssertEqual(estimate.timeIntervalSince(now), 400, accuracy: 0.001)
        job.state = .paused
        XCTAssertNil(job.estimatedCompletionDate(at: now))
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

    func testRecoveryPersistsKindSourceAndConfigurationAcrossReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportRecoveryStore(fileURL: root.appendingPathComponent("recovery.json"))
        let configuration = RouteFileImportConfiguration(
            mappingMode: .dedicatedTransport,
            dedicatedTransportMode: .cycling,
            existingDataPolicy: .overwriteExisting
        )
        let item = ImportRecoveryItem(
            displayName: "routes.gpx", originalFileName: "routes.gpx",
            source: ImportJobSourceMetadata(originalFileNames: ["routes.gpx"], sourceIdentifiers: ["/missing/routes.gpx"]),
            stagedPath: "/staged/routes.gpx", configuration: configuration,
            kind: .needsInformation, reason: "Choose a target date"
        )
        try store.save([item])
        let restored = try store.load()
        XCTAssertEqual(restored, [item])
        XCTAssertEqual(restored.first?.kind, .needsInformation)
        XCTAssertEqual(restored.first?.configuration, configuration)
        XCTAssertEqual(restored.first?.source.sourceIdentifiers, ["/missing/routes.gpx"])
    }

    func testAcquirerRetainsPartialStagingForRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.gpx")
        let missing = root.appendingPathComponent("missing.gpx")
        try Data("<gpx/>".utf8).write(to: first)

        XCTAssertThrowsError(try RouteImportAcquirer(stagingDirectory: staging).acquire(urls: [first, missing]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("000000-first.gpx").path))
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

    func testAcquirerCanLeaveFilesInPlaceForOneAtATimeImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("routes")
        let staging = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = folder.appendingPathComponent("first.gpx")
        let second = folder.appendingPathComponent("second.gpx")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let result = try RouteImportAcquirer(stagingDirectory: staging).acquire(
            urls: [folder],
            stageFiles: false
        )

        XCTAssertFalse(result.filesAreStaged)
        XCTAssertEqual(result.files, [first, second])
        XCTAssertEqual(result.accessRoots.map(\.path), [folder.path])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
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
            XCTAssertEqual(error as? RouteImportAcquisitionError, .stagingByteLimitExceeded(maximum: 9))
        }
    }

    func testDefaultAcquisitionLimitSupportsTwelveThousandFileExports() {
        XCTAssertGreaterThanOrEqual(
            RouteImportAcquisitionConfiguration().maximumStagedFiles,
            12_000
        )
    }

    func testImportConfigurationDefaultsNewFileHandlingModeWhenDecodingOlderData() throws {
        let data = Data(#"{"mappingMode":"automatic","dedicatedTransportMode":"unknown","existingDataPolicy":"skipDate"}"#.utf8)

        let configuration = try JSONDecoder().decode(RouteFileImportConfiguration.self, from: data)

        XCTAssertEqual(configuration.fileHandlingMode, .oneAtATime)
    }

    func testFailureReportExportsEscapedCSVAndReadableText() throws {
        let report = RouteFileFailureReport(
            displayName: "Large import",
            createdAt: Date(timeIntervalSince1970: 0),
            attemptedFileCount: 12_000,
            entries: [
                RouteFileFailureEntry(
                    fileName: "route, \"bad\".gpx",
                    sourceIdentifier: "/Routes/route, \"bad\".gpx",
                    reason: "Could not parse"
                )
            ]
        )

        let csv = try XCTUnwrap(String(data: report.exportData(format: .csv), encoding: .utf8))
        XCTAssertTrue(csv.hasPrefix("file_name,reason,source_identifier\n"))
        XCTAssertTrue(csv.contains(#""route, ""bad"".gpx","Could not parse","/Routes/route, ""bad"".gpx""#))

        let text = try XCTUnwrap(String(data: report.exportData(format: .text), encoding: .utf8))
        XCTAssertTrue(text.contains("Attempted files: 12000"))
        XCTAssertTrue(text.contains("Failed files: 1"))
        XCTAssertTrue(text.contains("route, \"bad\".gpx\tCould not parse\t/Routes/route, \"bad\".gpx"))
    }
}
