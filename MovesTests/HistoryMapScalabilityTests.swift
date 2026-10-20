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
        let calendar = Calendar.autoupdatingCurrent
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

    func testTenThousandRouteSamplesStayBoundedAndKeepEndpoints() {
        let indices = ShareMapAggregateStore.boundedSampleIndices(total: 10_000, limit: 1_000)

        XCTAssertEqual(indices.count, 1_000)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, 9_999)
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(Set(indices).count, indices.count)
    }

    @MainActor
    func testDayInvalidationRejectsOnlyTheStaleDayRequest() {
        let selectedDay = "2024-01-01"
        let adjacentDay = "2024-01-02"
        let selectedToken = TimelinePresentationEpochLedger.token(for: selectedDay)
        let adjacentToken = TimelinePresentationEpochLedger.token(for: adjacentDay)

        TimelinePresentationCacheInvalidator.invalidate(dayKey: selectedDay)

        XCTAssertFalse(TimelinePresentationEpochLedger.isCurrent(selectedToken, for: selectedDay))
        XCTAssertTrue(TimelinePresentationEpochLedger.isCurrent(adjacentToken, for: adjacentDay))
    }

    @MainActor
    func testHistoryAggregateSourceSignatureTracksRouteRevision() {
        let day = DayTimeline(dayStart: Date(timeIntervalSince1970: 1_700_000_000))
        let move = MoveSegment(
            dedupeKey: "synthetic-route-revision",
            startDate: day.dayStart.addingTimeInterval(60),
            endDate: day.dayStart.addingTimeInterval(600),
            transportMode: .walking,
            distanceMeters: 900,
            stepCount: nil
        )
        day.moves = [move]
        let originalSignature = ShareMapAggregateStore.sourceSignature(for: [day])

        move.routeCacheSignature = "route-revision-2"
        let updatedSignature = ShareMapAggregateStore.sourceSignature(for: [day])

        XCTAssertNotEqual(originalSignature, updatedSignature)
        XCTAssertEqual(updatedSignature, ShareMapAggregateStore.sourceSignature(for: [day]))
    }
}
