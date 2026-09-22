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
}
