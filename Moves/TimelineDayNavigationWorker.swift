import Foundation
import SwiftData

/// The small, relationship-free portion of a day needed to navigate the timeline.
/// It is safe to return from the navigation model actor and does not fault in a day's
/// places, moves, or location samples.
struct TimelineDayNavigationMetadata: Sendable, Equatable, Identifiable {
    let dayKey: String
    let dayStart: Date

    var id: String { dayKey }
}

struct TimelineDayNavigationWindow: Sendable, Equatable {
    let days: [TimelineDayNavigationMetadata]
    let hasOlderDays: Bool
    let hasNewerDays: Bool
}

/// Invalidates asynchronous date/ID lookup chains as soon as a newer selection starts.
@MainActor
final class TimelineDayNavigationRequestGate {
    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0

    func begin() -> Token {
        generation &+= 1
        return Token(generation: generation)
    }

    func isCurrent(_ token: Token) -> Bool { token.generation == generation }
}

/// Runs the bounded day-index queries away from the UI executor. Full day content is
/// loaded by TimelineDayPresentationWorker only after the selected page is presented.
@ModelActor
actor TimelineDayNavigationWorker {
    func newestDays(limit: Int) throws -> [TimelineDayNavigationMetadata] {
        var descriptor = FetchDescriptor<DayTimeline>(
            sortBy: [SortDescriptor(\.dayStart, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try modelContext.fetch(descriptor).map(TimelineDayNavigationMetadata.init)
    }

    func day(dayKey: String) throws -> TimelineDayNavigationMetadata? {
        var descriptor = FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayKey == dayKey })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(TimelineDayNavigationMetadata.init)
    }

    func day(containingPlaceID placeID: UUID) throws -> TimelineDayNavigationMetadata? {
        var descriptor = FetchDescriptor<VisitPlace>(predicate: #Predicate { $0.id == placeID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.dayTimeline.map(TimelineDayNavigationMetadata.init)
    }

    func nearestDay(to date: Date) throws -> TimelineDayNavigationMetadata? {
        var before = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { $0.dayStart <= date },
            sortBy: [SortDescriptor(\.dayStart, order: .reverse)]
        )
        before.fetchLimit = 1
        var after = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { $0.dayStart > date },
            sortBy: [SortDescriptor(\.dayStart, order: .forward)]
        )
        after.fetchLimit = 1
        return try (modelContext.fetch(before) + modelContext.fetch(after))
            .min { abs($0.dayStart.timeIntervalSince(date)) < abs($1.dayStart.timeIntervalSince(date)) }
            .map(TimelineDayNavigationMetadata.init)
    }

    func window(around date: Date, limit: Int) throws -> TimelineDayNavigationWindow {
        let olderCount = max(0, limit / 2)
        let newerCount = max(0, limit - olderCount - 1)
        var older = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { $0.dayStart < date },
            sortBy: [SortDescriptor(\.dayStart, order: .reverse)]
        )
        older.fetchLimit = olderCount
        var center = FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayStart == date })
        center.fetchLimit = 1
        var newer = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { $0.dayStart > date },
            sortBy: [SortDescriptor(\.dayStart, order: .forward)]
        )
        newer.fetchLimit = newerCount
        let olderRows = try modelContext.fetch(older).reversed()
        let centerRows = try modelContext.fetch(center)
        let newerRows = try modelContext.fetch(newer)
        let days = (Array(olderRows) + centerRows + newerRows).map(TimelineDayNavigationMetadata.init)
        let firstDate = days.first?.dayStart
        let lastDate = days.last?.dayStart
        return TimelineDayNavigationWindow(
            days: days,
            hasOlderDays: try firstDate.map(hasDay(olderThan:)) ?? false,
            hasNewerDays: try lastDate.map(hasDay(newerThan:)) ?? false
        )
    }

    func recentWindow(limit: Int, sidebarLimit: Int) throws -> TimelineDayNavigationWindow {
        let days = try newestDays(limit: sidebarLimit)
        let pager = Array(days.prefix(max(0, limit)).reversed())
        guard let first = pager.first, let last = pager.last else {
            return TimelineDayNavigationWindow(days: pager, hasOlderDays: false, hasNewerDays: false)
        }
        return TimelineDayNavigationWindow(
            days: pager,
            hasOlderDays: try hasDay(olderThan: first.dayStart),
            hasNewerDays: try hasDay(newerThan: last.dayStart)
        )
    }

    private func hasDay(olderThan date: Date) throws -> Bool {
        var descriptor = FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayStart < date })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func hasDay(newerThan date: Date) throws -> Bool {
        var descriptor = FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayStart > date })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }
}

extension TimelineDayNavigationMetadata {
    init(_ day: DayTimeline) {
        dayKey = day.dayKey
        dayStart = day.dayStart
    }
}
