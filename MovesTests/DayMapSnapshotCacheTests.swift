import UIKit
import XCTest
@testable import Moves

@MainActor
final class DayMapSnapshotCacheTests: XCTestCase {
    func testInvalidatingOneDayPreservesOtherDaysMemorySnapshot() {
        DayMapSnapshotCache.removeAll()
        defer { DayMapSnapshotCache.removeAll() }

        let first = UIImage(systemName: "1.circle")!
        let second = UIImage(systemName: "2.circle")!
        DayMapSnapshotCache.store(first, for: "day-a-map", dayKey: "day-a")
        DayMapSnapshotCache.store(second, for: "day-b-map", dayKey: "day-b")

        DayMapSnapshotCache.remove(dayKey: "day-a")

        XCTAssertNil(DayMapSnapshotCache.cachedImage(for: "day-a-map"))
        XCTAssertNotNil(DayMapSnapshotCache.cachedImage(for: "day-b-map"))
    }

    func testConcurrentRequestsForSameKeyShareGeneration() async throws {
        DayMapSnapshotCache.removeAll()
        defer { DayMapSnapshotCache.removeAll() }
        let counter = SnapshotGenerationCounter()
        let first = Task {
            try await DayMapSnapshotCache.imageOrGenerate(for: "dedupe-map", dayKey: "dedupe-day") {
                await counter.increment()
                try await Task.sleep(for: .milliseconds(100))
                return UIImage(systemName: "map")!
            }
        }
        let second = Task {
            try await DayMapSnapshotCache.imageOrGenerate(for: "dedupe-map", dayKey: "dedupe-day") {
                await counter.increment()
                try await Task.sleep(for: .milliseconds(100))
                return UIImage(systemName: "map")!
            }
        }

        _ = try await (first.value, second.value)
        let generationCount = await counter.value
        XCTAssertEqual(generationCount, 1)
    }

    func testLastCancelledConsumerCancelsSnapshotGeneration() async {
        DayMapSnapshotCache.removeAll()
        defer { DayMapSnapshotCache.removeAll() }
        let state = SnapshotCancellationState()
        let consumer = Task {
            try await DayMapSnapshotCache.imageOrGenerate(for: "cancel-map", dayKey: "cancel-day") {
                await state.didStart()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return UIImage(systemName: "map")!
                } catch {
                    await state.didCancel()
                    throw error
                }
            }
        }

        while !(await state.started) { try? await Task.sleep(for: .milliseconds(5)) }
        consumer.cancel()
        _ = try? await consumer.value
        let generationWasCancelled = await state.cancelled
        XCTAssertTrue(generationWasCancelled)
    }
}

@MainActor
private final class SnapshotGenerationCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

@MainActor
private final class SnapshotCancellationState {
    private(set) var started = false
    private(set) var cancelled = false

    func didStart() { started = true }
    func didCancel() { cancelled = true }
}
