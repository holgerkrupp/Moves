import Foundation
import SwiftData
import XCTest
@testable import Moves

final class TimelineDayNavigationWorkerTests: XCTestCase {
    func testNavigationMetadataIsBoundedAndRelationshipFreeForLargeHistory() async throws {
        let container = try MovesTimelineStore.makeApplicationContainer(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none
        )
        let context = ModelContext(container)
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.startOfDay(for: .now)
        for offset in 0..<10_000 {
            context.insert(DayTimeline(dayStart: calendar.date(byAdding: .day, value: -offset, to: anchor)!))
        }
        try context.save()

        let worker = TimelineDayNavigationWorker(modelContainer: container)
        let window = try await worker.recentWindow(limit: 5, sidebarLimit: 60)

        XCTAssertEqual(window.days.count, 5)
        XCTAssertEqual(window.days.first?.dayStart, calendar.date(byAdding: .day, value: -4, to: anchor))
        XCTAssertEqual(window.days.last?.dayStart, anchor)
        XCTAssertTrue(window.hasOlderDays)
        XCTAssertFalse(window.hasNewerDays)
        XCTAssertTrue(window.days.allSatisfy { $0.dayKey == DayTimeline.makeDayKey(for: $0.dayStart) })
    }

    func testDateJumpWindowChoosesNearestStoredDayAndIsBounded() async throws {
        let container = try MovesTimelineStore.makeApplicationContainer(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none
        )
        let context = ModelContext(container)
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.startOfDay(for: .now)
        for offset in 0...10 {
            context.insert(DayTimeline(dayStart: calendar.date(byAdding: .day, value: -offset, to: anchor)!))
        }
        try context.save()

        let worker = TimelineDayNavigationWorker(modelContainer: container)
        let near = calendar.date(byAdding: .day, value: -5, to: anchor)!
        let maybeCenter = try await worker.nearestDay(to: near)
        let center = try XCTUnwrap(maybeCenter)
        let window = try await worker.window(around: center.dayStart, limit: 5)

        XCTAssertEqual(center.dayStart, calendar.date(byAdding: .day, value: -5, to: anchor))
        XCTAssertEqual(window.days.count, 5)
        XCTAssertTrue(window.hasOlderDays)
        XCTAssertTrue(window.hasNewerDays)
    }
}
