import XCTest
@testable import Moves

final class HistoryMapScalabilityTests: XCTestCase {
    func testBoundedTrackSamplingPreservesTemporalEndpointsAndLimit() {
        XCTAssertEqual(ShareMapAggregateStore.boundedSampleIndices(total: 0, limit: 10), [])
        XCTAssertEqual(ShareMapAggregateStore.boundedSampleIndices(total: 4, limit: 10), [0, 1, 2, 3])

        let indices = ShareMapAggregateStore.boundedSampleIndices(total: 12_000, limit: 1_200)
        XCTAssertEqual(indices.count, 1_200)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, 11_999)
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(Set(indices).count, indices.count)
    }

    func testAggregatePeriodIntervalsRespectCalendarBoundaries() throws {
        var calendar = Calendar.autoupdatingCurrent
        let january = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
        let february = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 1)))
        let nextYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))

        let januaryInterval = try XCTUnwrap(ShareMapAggregateStore.dateInterval(for: "month:2024-01"))
        let yearInterval = try XCTUnwrap(ShareMapAggregateStore.dateInterval(for: "year:2024"))
        XCTAssertEqual(januaryInterval.start, january)
        XCTAssertEqual(januaryInterval.end, february)
        XCTAssertEqual(yearInterval.start, january)
        XCTAssertEqual(yearInterval.end, nextYear)
    }
}
