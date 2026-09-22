import CoreLocation
import Foundation
import MapKit
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Share images

enum MovesSharePeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year
    case forever

    var id: Self { self }

    var title: String {
        switch self {
        case .day: return "Days"
        case .week: return "Weeks"
        case .month: return "Months"
        case .year: return "Years"
        case .forever: return "Forever"
        }
    }

    var singularTitle: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .forever: return "Forever"
        }
    }

    var includesAllTracks: Bool {
        switch self {
        case .day, .week, .month, .year:
            return true
        case .forever:
            return false
        }
    }

    var buildsTracksDirectly: Bool {
        self == .day || self == .week || self == .month
    }

    var includesCalendar: Bool { self == .month }

    func start(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        switch self {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .year:
            let components = calendar.dateComponents([.year], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .forever:
            return .distantPast
        }
    }

    func dateInterval(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval? {
        guard self != .forever else { return nil }
        let periodStart = start(for: date, calendar: calendar)
        let component: Calendar.Component
        switch self {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        case .forever: return nil
        }
        let periodEnd = calendar.date(byAdding: component, value: 1, to: periodStart) ?? periodStart
        return DateInterval(start: periodStart, end: periodEnd)
    }

    func contains(
        _ date: Date,
        periodStart: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard let interval = dateInterval(containing: periodStart, calendar: calendar) else {
            return true
        }
        return date >= interval.start && date < interval.end
    }

    func adding(_ value: Int, to date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        guard self != .forever else { return .distantPast }
        let component: Calendar.Component
        switch self {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        case .forever: return .distantPast
        }
        let shifted = calendar.date(byAdding: component, value: value, to: date) ?? date
        return start(for: shifted, calendar: calendar)
    }

    func label(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        switch self {
        case .day:
            return date.formatted(.dateTime.day().month(.abbreviated).year())
        case .week:
            let start = start(for: date, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            let formatter = DateIntervalFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.calendar = calendar
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: start, to: end)
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        case .year:
            return date.formatted(.dateTime.year())
        case .forever:
            return "Forever"
        }
    }

    func gpxFileStem(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        guard self != .forever else { return "moves-all-days" }

        let periodStart = start(for: date, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day], from: periodStart)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        switch self {
        case .day:
            return String(format: "moves-%04d-%02d-%02d", year, month, day)
        case .week:
            return String(format: "moves-week-%04d-%02d-%02d", year, month, day)
        case .month:
            return String(format: "moves-%04d-%02d", year, month)
        case .year:
            return String(format: "moves-%04d", year)
        case .forever:
            return "moves-all-days"
        }
    }
}

enum MovesShareHeatScale {
    static func intensity(frequency: Int, maximum: Int) -> CGFloat {
        guard frequency > 1 else { return 0 }

        // Keep the scale meaningful even when the selected period only contains
        // a few repetitions, while still adapting to periods with much more data.
        let absolute = min(log2(Double(frequency)) / 4, 1)
        let relative: Double
        if maximum > 1 {
            relative = min(log(Double(frequency)) / log(Double(maximum)), 1)
        } else {
            relative = 0
        }
        return CGFloat(min(max(absolute * 0.8 + relative * 0.2, 0), 1))
    }
}

private struct MovesSharePlace: Identifiable {
    let id: String
    let title: String
    let visitCount: Int
    let totalDuration: TimeInterval
    let dayCount: Int
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct MovesShareDay: Identifiable {
    let id: String
    let date: Date
    let distanceMeters: CLLocationDistance
    let moveDuration: TimeInterval
    let placeCount: Int
    let moveCount: Int
    let activityScore: Double
}

private struct MovesShareTransport: Identifiable {
    let mode: TransportMode
    let distanceMeters: CLLocationDistance
    let duration: TimeInterval
    let segmentCount: Int

    var id: String { mode.rawValue }
}

private struct MovesShareTrack: Identifiable {
    let id: UUID
    let transportMode: TransportMode
    let coordinates: [CLLocationCoordinate2D]
}

private struct MovesShareHeatTrack: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let usageCount: Int
}

private struct MovesShareCalendarDay: Identifiable {
    let id: String
    let date: Date
    let placeCoordinates: [CLLocationCoordinate2D]
    let tracks: [MovesShareTrack]
    let placeCount: Int
    let moveCount: Int
    let distanceMeters: CLLocationDistance
}

private struct MovesShareSnapshot {
    let periodLabel: String
    let recordedDayCount: Int
    let uniquePlaceCount: Int
    let visitCount: Int
    let moveCount: Int
    let totalDistanceMeters: CLLocationDistance
    let totalMoveDuration: TimeInterval
    let totalStepCount: Int
    let longestMoveMeters: CLLocationDistance
    let busiestWeekday: String?
    let topPlaces: [MovesSharePlace]
    let activeDays: [MovesShareDay]
    let transports: [MovesShareTransport]
    let tracks: [MovesShareTrack]
    let heatTracks: [MovesShareHeatTrack]
    let calendarDays: [MovesShareCalendarDay]

    var hasContent: Bool {
        visitCount > 0 || moveCount > 0
    }

    static func make(
        from timelines: [DayTimeline],
        period: MovesSharePeriod,
        periodStart: Date,
        aggregateTracks: [ShareMapAggregateTrack]? = nil,
        now: Date = .now
    ) -> MovesShareSnapshot {
        let calendar = Calendar.autoupdatingCurrent
        let selectedTimelines: [DayTimeline]
        if period != .forever {
            selectedTimelines = timelines.filter {
                period.contains($0.dayStart, periodStart: periodStart, calendar: calendar)
            }
        } else {
            selectedTimelines = timelines
        }

        let recordedDays = selectedTimelines.filter(\.hasRecordedActivity)
        let allPlaces = selectedTimelines.flatMap(\.places)
        let allMoves = selectedTimelines.flatMap(\.moves)

        struct PlaceAccumulator {
            var title: String
            var titlePriority: Int
            var visits = 0
            var duration: TimeInterval = 0
            var dayKeys = Set<String>()
            var latitude: Double
            var longitude: Double
        }

        var placesByCoordinate: [String: PlaceAccumulator] = [:]
        for place in allPlaces {
            let latitudeBucket = Int((place.latitude * 10_000).rounded())
            let longitudeBucket = Int((place.longitude * 10_000).rounded())
            let key = "\(latitudeBucket)|\(longitudeBucket)"
            let userLabel = place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let autoLabel = place.autoLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateTitle: String
            let candidatePriority: Int

            if let userLabel, !userLabel.isEmpty {
                candidateTitle = userLabel
                candidatePriority = 2
            } else if let autoLabel, !autoLabel.isEmpty {
                candidateTitle = autoLabel
                candidatePriority = 1
            } else {
                candidateTitle = place.displayTitle
                candidatePriority = 0
            }

            var accumulator = placesByCoordinate[key] ?? PlaceAccumulator(
                title: candidateTitle,
                titlePriority: candidatePriority,
                latitude: place.latitude,
                longitude: place.longitude
            )
            if candidatePriority > accumulator.titlePriority {
                accumulator.title = candidateTitle
                accumulator.titlePriority = candidatePriority
            }
            accumulator.visits += 1
            let fallbackDeparture = min(
                now,
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: place.arrivalDate)) ?? now
            )
            accumulator.duration += max((place.departureDate ?? fallbackDeparture).timeIntervalSince(place.arrivalDate), 0)
            accumulator.dayKeys.insert(place.dayTimeline?.dayKey ?? DayTimeline.makeDayKey(for: place.arrivalDate))
            placesByCoordinate[key] = accumulator
        }

        let topPlaces = placesByCoordinate.map { key, value in
            MovesSharePlace(
                id: key,
                title: value.title,
                visitCount: value.visits,
                totalDuration: value.duration,
                dayCount: value.dayKeys.count,
                latitude: value.latitude,
                longitude: value.longitude
            )
        }
        .sorted {
            if $0.visitCount == $1.visitCount {
                if $0.totalDuration == $1.totalDuration {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.totalDuration > $1.totalDuration
            }
            return $0.visitCount > $1.visitCount
        }

        let activeDays = recordedDays.map { day in
            let distance = day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
            let duration = day.moves.reduce(0) { $0 + max($1.timelineDuration, 0) }
            let score = distance + duration / 4 + Double(day.uniqueLocationCount) * 500 + Double(day.moves.count) * 250
            return MovesShareDay(
                id: day.dayKey,
                date: day.dayStart,
                distanceMeters: distance,
                moveDuration: duration,
                placeCount: day.uniqueLocationCount,
                moveCount: day.moves.count,
                activityScore: score
            )
        }
        .sorted {
            if $0.activityScore == $1.activityScore {
                return $0.date > $1.date
            }
            return $0.activityScore > $1.activityScore
        }

        let transports = TransportMode.allCases.compactMap { mode -> MovesShareTransport? in
            guard mode != .stationary else { return nil }
            let moves = allMoves.filter { $0.transportMode == mode }
            guard !moves.isEmpty else { return nil }
            return MovesShareTransport(
                mode: mode,
                distanceMeters: moves.reduce(0) { $0 + max($1.distanceMeters, 0) },
                duration: moves.reduce(0) { $0 + max($1.timelineDuration, 0) },
                segmentCount: moves.count
            )
        }
        .sorted {
            if $0.distanceMeters == $1.distanceMeters {
                return $0.duration > $1.duration
            }
            return $0.distanceMeters > $1.distanceMeters
        }

        let tracks: [MovesShareTrack]
        if let aggregateTracks {
            tracks = aggregateTracks.map {
                MovesShareTrack(
                    id: $0.id,
                    transportMode: $0.transportMode,
                    coordinates: $0.coordinates
                )
            }
        } else if period.buildsTracksDirectly {
            tracks = allMoves.compactMap { move -> MovesShareTrack? in
                let fallback = MoveRouteGeometry.rawCoordinates(for: move)
                let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
                let coordinates = move.manualRouteCoordinates
                    ?? move.cachedRouteCoordinates(for: signature)
                    ?? fallback
                guard coordinates.count > 1 else { return nil }
                return MovesShareTrack(
                    id: move.id,
                    transportMode: move.transportMode,
                    coordinates: coordinates
                )
            }
        } else {
            tracks = []
        }

        let heatTracks: [MovesShareHeatTrack]
        if !tracks.isEmpty {
            heatTracks = groupedHeatTracks(from: tracks)
        } else {
            heatTracks = groupedHeatTracks(from: allMoves)
        }

        let calendarDays: [MovesShareCalendarDay]
        if period.includesCalendar {
            let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            calendarDays = recordedDays.map { day in
                MovesShareCalendarDay(
                    id: day.dayKey,
                    date: day.dayStart,
                    placeCoordinates: day.places.map(\.coordinate),
                    tracks: day.moves.compactMap { tracksByID[$0.id] }.map {
                        MovesShareTrack(
                            id: $0.id,
                            transportMode: $0.transportMode,
                            coordinates: downsampled($0.coordinates, maximumCount: 90)
                        )
                    },
                    placeCount: day.uniqueLocationCount,
                    moveCount: day.moves.count,
                    distanceMeters: day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
                )
            }
        } else {
            calendarDays = []
        }

        let weekdayTotals = Dictionary(grouping: activeDays) { day in
            calendar.component(.weekday, from: day.date)
        }
        let busiestWeekdayNumber = weekdayTotals.max { lhs, rhs in
            let leftScore = lhs.value.reduce(0) { $0 + $1.activityScore }
            let rightScore = rhs.value.reduce(0) { $0 + $1.activityScore }
            return leftScore < rightScore
        }?.key
        let busiestWeekday: String?
        if let weekday = busiestWeekdayNumber {
            let symbols = DateFormatter().weekdaySymbols ?? []
            busiestWeekday = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : nil
        } else {
            busiestWeekday = nil
        }

        let periodLabel: String
        if period == .forever {
            let sortedDates = recordedDays.map(\.dayStart).sorted()
            if let first = sortedDates.first, let last = sortedDates.last {
                if calendar.isDate(first, inSameDayAs: last) {
                    periodLabel = first.formatted(.dateTime.day().month(.abbreviated).year())
                } else {
                    periodLabel = "\(first.formatted(.dateTime.day().month(.abbreviated).year())) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
                }
            } else {
                periodLabel = "No recorded activity"
            }
        } else {
            periodLabel = period.label(for: periodStart, calendar: calendar)
        }

        return MovesShareSnapshot(
            periodLabel: periodLabel,
            recordedDayCount: recordedDays.count,
            uniquePlaceCount: placesByCoordinate.count,
            visitCount: allPlaces.count,
            moveCount: allMoves.count,
            totalDistanceMeters: allMoves.reduce(0) { $0 + max($1.distanceMeters, 0) },
            totalMoveDuration: allMoves.reduce(0) { $0 + max($1.timelineDuration, 0) },
            totalStepCount: allMoves.compactMap(\.stepCount).reduce(0, +),
            longestMoveMeters: allMoves.map(\.distanceMeters).max() ?? 0,
            busiestWeekday: busiestWeekday,
            topPlaces: topPlaces,
            activeDays: activeDays,
            transports: transports,
            tracks: tracks,
            heatTracks: heatTracks,
            calendarDays: calendarDays
        )
    }

    private static func groupedHeatTracks(from moves: [MoveSegment]) -> [MovesShareHeatTrack] {
        struct RouteAccumulator {
            var representative: MoveSegment
            var usageCount: Int
        }

        func coordinateKey(_ coordinate: CLLocationCoordinate2D) -> String {
            let latitude = Int((coordinate.latitude * 1_000).rounded())
            let longitude = Int((coordinate.longitude * 1_000).rounded())
            return "\(latitude):\(longitude)"
        }

        var routes: [String: RouteAccumulator] = [:]
        for move in moves {
            guard let start = move.startPlace?.coordinate,
                  let end = move.endPlace?.coordinate else { continue }
            let endpoints = [coordinateKey(start), coordinateKey(end)].sorted()
            let key = endpoints.joined(separator: "|")
            var route = routes[key] ?? RouteAccumulator(representative: move, usageCount: 0)
            route.usageCount += 1

            let currentBytes = route.representative.manualRouteCoordinatesData?.count
                ?? route.representative.routeCacheCoordinatesData?.count
                ?? 0
            let candidateBytes = move.manualRouteCoordinatesData?.count
                ?? move.routeCacheCoordinatesData?.count
                ?? 0
            if candidateBytes > currentBytes {
                route.representative = move
            }
            routes[key] = route
        }

        return routes.values
            .sorted {
                if $0.usageCount == $1.usageCount {
                    return $0.representative.distanceMeters > $1.representative.distanceMeters
                }
                return $0.usageCount > $1.usageCount
            }
            .prefix(160)
            .compactMap { route -> MovesShareHeatTrack? in
                let move = route.representative
                let fallback = MoveRouteGeometry.rawCoordinates(for: move)
                let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
                let coordinates = move.manualRouteCoordinates
                    ?? move.cachedRouteCoordinates(for: signature)
                    ?? fallback
                guard coordinates.count > 1 else { return nil }
                return MovesShareHeatTrack(
                    id: move.id,
                    coordinates: downsampled(coordinates, maximumCount: 120),
                    usageCount: route.usageCount
                )
            }
    }

    private static func groupedHeatTracks(from tracks: [MovesShareTrack]) -> [MovesShareHeatTrack] {
        struct RouteAccumulator {
            var representative: MovesShareTrack
            var usageCount: Int
        }

        func coordinateKey(_ coordinate: CLLocationCoordinate2D) -> String {
            let latitude = Int((coordinate.latitude * 1_000).rounded())
            let longitude = Int((coordinate.longitude * 1_000).rounded())
            return "\(latitude):\(longitude)"
        }

        var routes: [String: RouteAccumulator] = [:]
        for track in tracks {
            guard let start = track.coordinates.first,
                  let end = track.coordinates.last else { continue }
            let endpoints = [coordinateKey(start), coordinateKey(end)].sorted()
            let key = endpoints.joined(separator: "|")
            var route = routes[key] ?? RouteAccumulator(representative: track, usageCount: 0)
            route.usageCount += 1
            if track.coordinates.count > route.representative.coordinates.count {
                route.representative = track
            }
            routes[key] = route
        }

        return routes.values
            .sorted {
                if $0.usageCount == $1.usageCount {
                    return $0.representative.coordinates.count > $1.representative.coordinates.count
                }
                return $0.usageCount > $1.usageCount
            }
            .prefix(160)
            .map { route in
                MovesShareHeatTrack(
                    id: route.representative.id,
                    coordinates: downsampled(route.representative.coordinates, maximumCount: 160),
                    usageCount: route.usageCount
                )
            }
    }

    private static func downsampled(
        _ coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount, maximumCount > 1 else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            coordinates[min(Int((Double(index) * step).rounded()), coordinates.count - 1)]
        }
    }
}

private enum MovesShareDesign: String, CaseIterable, Identifiable {
    case overview
    case places
    case placeMap
    case activeDays
    case transport
    case tracks
    case heatMap
    case calendar

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .places: return "Top Places"
        case .placeMap: return "Places Map"
        case .activeDays: return "Active Days"
        case .transport: return "Transport Mix"
        case .tracks: return "All Tracks"
        case .heatMap: return "Heat Map"
        case .calendar: return "Calendar"
        }
    }
}

private enum MovesShareMapStyle: String, CaseIterable, Identifiable {
    case standard
    case muted
    case satellite
    case hybrid
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: return "Map"
        case .muted: return "Muted"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        case .dark: return "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: return "map"
        case .muted: return "map.fill"
        case .satellite: return "globe.americas.fill"
        case .hybrid: return "square.3.layers.3d"
        case .dark: return "moon.stars.fill"
        }
    }

    var mapType: MKMapType {
        switch self {
        case .standard, .dark: return .standard
        case .muted: return .mutedStandard
        case .satellite: return .satellite
        case .hybrid: return .hybrid
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        self == .dark ? .dark : .light
    }
}

private enum MovesShareBackground: String, CaseIterable, Identifiable {
    case moves
    case sunrise
    case midnight
    case rainbow
    case light

    var id: Self { self }

    var title: String {
        switch self {
        case .moves: return "Moves"
        case .sunrise: return "Sunrise"
        case .midnight: return "Midnight"
        case .rainbow: return "Rainbow"
        case .light: return "Light"
        }
    }

    var isLight: Bool { self == .light }
}

private enum MovesShareAspect: String, CaseIterable, Identifiable {
    case portrait
    case square
    case landscape

    var id: Self { self }

    var title: String {
        switch self {
        case .portrait: return "Portrait"
        case .square: return "Square"
        case .landscape: return "Landscape"
        }
    }

    var renderSize: CGSize {
        switch self {
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1920, height: 1080)
        }
    }

    var mapRenderSize: CGSize {
        switch self {
        case .portrait: return CGSize(width: 920, height: 1_250)
        case .square: return CGSize(width: 920, height: 650)
        case .landscape: return CGSize(width: 1_650, height: 650)
        }
    }

    var calendarMapRenderSize: CGSize {
        switch self {
        case .portrait: return CGSize(width: 220, height: 300)
        case .square: return CGSize(width: 220, height: 190)
        case .landscape: return CGSize(width: 260, height: 190)
        }
    }

    var ratio: CGFloat { renderSize.width / renderSize.height }
}

struct MovesShareGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let dayTimelines: [DayTimeline]
    private let showsDismissButton: Bool
    @State private var selectedPeriod: MovesSharePeriod = .day
    @State private var selectedDate: Date
    @State private var shareTitle = "My Moves"
    @State private var background: MovesShareBackground = .moves
    @State private var aspect: MovesShareAspect = .portrait
    @State private var mapStyle: MovesShareMapStyle = .standard
    @State private var snapshot: MovesShareSnapshot
    @State private var snapshotDataSignature: String
    @State private var renderedImages: [MovesShareDesign: UIImage] = [:]
    @State private var cachedCalendarMapImages: [String: UIImage] = [:]
    @State private var cachedCalendarMapSignature = ""
    @State private var selectedDesigns = Set<MovesShareDesign>()
    @State private var isRendering = false
    @State private var renderedCount = 0
    @State private var gpxShareFile: GPXShareFile?
    @State private var isPreparingGPX = false
    @State private var activityItems: [Any] = []
    @State private var showsShareSheet = false
    @State private var isShowingDatePicker = false

    init(
        dayTimelines: [DayTimeline],
        initialDate: Date,
        showsDismissButton: Bool = true
    ) {
        self.dayTimelines = dayTimelines
        self.showsDismissButton = showsDismissButton
        _selectedDate = State(initialValue: initialDate)
        let initialPeriodStart = MovesSharePeriod.day.start(for: initialDate)
        _snapshot = State(initialValue: MovesShareSnapshot.make(
            from: dayTimelines,
            period: .day,
            periodStart: initialPeriodStart
        ))
        _snapshotDataSignature = State(initialValue: Self.makeDataSignature(
            timelines: dayTimelines,
            period: .day,
            periodStart: initialPeriodStart
        ))
    }

    private var selectedPeriodStart: Date {
        selectedPeriod.start(for: selectedDate)
    }

    private var effectiveTitle: String {
        let trimmed = shareTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "My Moves" : trimmed
    }

    private var availableDesigns: [MovesShareDesign] {
        availableDesigns(for: snapshot)
    }

    private func availableDesigns(for snapshot: MovesShareSnapshot) -> [MovesShareDesign] {
        MovesShareDesign.allCases.filter { design in
            switch design {
            case .overview: return snapshot.hasContent
            case .places: return !snapshot.topPlaces.isEmpty
            case .placeMap: return !snapshot.topPlaces.isEmpty
            case .activeDays: return !snapshot.activeDays.isEmpty
            case .transport: return !snapshot.transports.isEmpty
            case .tracks: return selectedPeriod.includesAllTracks && !snapshot.tracks.isEmpty
            case .heatMap: return !snapshot.topPlaces.isEmpty || !snapshot.heatTracks.isEmpty
            case .calendar: return selectedPeriod.includesCalendar && !snapshot.calendarDays.isEmpty
            }
        }
    }

    private var canMoveToNextPeriod: Bool {
        guard selectedPeriod != .forever else { return false }
        return selectedPeriodStart < selectedPeriod.start(for: .now)
    }

    private var renderSignature: String {
        [
            effectiveTitle,
            background.rawValue,
            aspect.rawValue,
            mapStyle.rawValue,
            currentDataSignature
        ].joined(separator: "|")
    }

    private var currentDataSignature: String {
        Self.makeDataSignature(
            timelines: dayTimelines,
            period: selectedPeriod,
            periodStart: selectedPeriodStart
        )
    }

    private var selectedTimelines: [DayTimeline] {
        guard selectedPeriod != .forever else { return dayTimelines }
        return dayTimelines.filter {
            selectedPeriod.contains($0.dayStart, periodStart: selectedPeriodStart)
        }
    }

    private static func makeDataSignature(
        timelines: [DayTimeline],
        period: MovesSharePeriod,
        periodStart: Date
    ) -> String {
        let timelineSignature = timelines.map { day in
            let distance = day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
            let routeBytes = day.moves.reduce(0) {
                $0 + ($1.manualRouteCoordinatesData?.count ?? 0) + ($1.routeCacheCoordinatesData?.count ?? 0)
            }
            return "\(day.dayKey):\(day.places.count):\(day.moves.count):\(Int(distance.rounded())):\(routeBytes)"
        }
        .joined(separator: ";")
        return "\(period.rawValue)|\(periodStart.timeIntervalSinceReferenceDate)|\(timelineSignature)"
    }

    private var canShareSelection: Bool {
        !selectedDesigns.isEmpty && selectedDesigns.allSatisfy { renderedImages[$0] != nil }
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $selectedPeriod) {
                    ForEach(MovesSharePeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    Button {
                        moveSelectedPeriod(by: -1)
                    } label: {
                        Label("", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Move to previous \(selectedPeriod.singularTitle.lowercased())")
                    .disabled(selectedPeriod == .forever)

                    Spacer(minLength: 8)

                    Button {
                        isShowingDatePicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                            Text(selectedPeriod.label(for: selectedPeriodStart))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedPeriod == .forever)
                    .accessibilityLabel("Jump to date")

                    Spacer(minLength: 8)

                    Button {
                        moveSelectedPeriod(by: 1)
                    } label: {
                        Label("", systemImage: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Move to next \(selectedPeriod.singularTitle.lowercased())")
                    .disabled(!canMoveToNextPeriod)
                }
            }

            if !snapshot.hasContent {
                ContentUnavailableView(
                    "No Share Images",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("There are no recorded places or movements in this time span.")
                )
            } else {
                Section {
                    NavigationLink {
                        MovesShareCustomizeView(
                            title: $shareTitle,
                            background: $background,
                            aspect: $aspect,
                            mapStyle: $mapStyle
                        )
                    } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("\(effectiveTitle) · \(aspect.title) · \(background.title) · \(mapStyle.title) map")
                }

                Section {
                    if isRendering {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(
                                value: Double(renderedCount),
                                total: Double(max(availableDesigns.count, 1))
                            )
                            Text("Rendering \(renderedCount) of \(availableDesigns.count) share images")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                    }

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(availableDesigns) { design in
                            MovesSharePreviewTile(
                                title: design.title,
                                image: renderedImages[design],
                                aspectRatio: aspect.ratio,
                                isSelected: selectedDesigns.contains(design),
                                selectAction: { toggleSelection(design) },
                                shareAction: { share([design]) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Designs")
                } footer: {
                    Text("Tap images to select several, or use the share button on a single design. Statistics are calculated entirely on this device.")
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                Section {
                    if let gpxShareFile {
                        ShareLink(
                            item: gpxShareFile,
                            subject: Text("Moves · \(selectedPeriod.label(for: selectedPeriodStart))"),
                            message: Text("GPX timeline exported from Moves."),
                            preview: SharePreview(gpxShareFile.filename)
                        ) {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Share GPX")
                                        .foregroundStyle(.primary)
                                    Text(gpxShareFile.filename)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            } icon: {
                                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    } else if isPreparingGPX {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Preparing GPX export…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("No GPX data in this time span", systemImage: "map")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("GPX Track")
                } footer: {
                    Text("Includes the visited locations and movement tracks from the selected time span.")
                }
            }
        }
        .navigationTitle("Share Images")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    share(Array(selectedDesigns))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!canShareSelection)
                .accessibilityLabel(selectedDesigns.count == 1 ? "Share Selected Image" : "Share Selected Images")
            }
        }
        .task(id: renderSignature) {
            await renderImages()
        }
        .task(id: currentDataSignature) {
            await prepareGPXShareFile()
        }
        .sheet(isPresented: $showsShareSheet, onDismiss: { activityItems = [] }) {
            MovesActivityView(activityItems: activityItems)
        }
        .sheet(isPresented: $isShowingDatePicker) {
            MovesJumpToDateView(
                dayTimelines: dayTimelines,
                selectedDate: selectedDate,
                onSelectDate: { selectedDate = $0 },
                onDismiss: { isShowingDatePicker = false }
            )
        }
    }

    private func moveSelectedPeriod(by amount: Int) {
        guard selectedPeriod != .forever else { return }
        selectedDate = selectedPeriod.adding(amount, to: selectedPeriodStart)
    }

    private func toggleSelection(_ design: MovesShareDesign) {
        if selectedDesigns.contains(design) {
            selectedDesigns.remove(design)
        } else {
            selectedDesigns.insert(design)
        }
    }

    private func share(_ designs: [MovesShareDesign]) {
        let images = designs.compactMap { renderedImages[$0] }
        guard !images.isEmpty else { return }
        activityItems = images
        showsShareSheet = true
    }

    @MainActor
    private func prepareGPXShareFile() async {
        gpxShareFile = nil
        isPreparingGPX = true
        defer { isPreparingGPX = false }

        let period = selectedPeriod
        let periodStart = selectedPeriodStart
        let container = modelContext.container
        let work = Task<TimelineExportPayload?, Never>.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<DayTimeline>(
                sortBy: [SortDescriptor(\.dayStart, order: .forward)]
            )
            guard let timelines = try? context.fetch(descriptor) else { return nil }
            let days = timelines.filter { day in
                (period == .forever || period.contains(day.dayStart, periodStart: periodStart))
                    && (!day.places.isEmpty || !day.moves.isEmpty)
            }
            guard !days.isEmpty else { return nil }
            return TimelineExporter.makePayload(
                days: days,
                format: .gpx,
                fileStem: period.gpxFileStem(for: periodStart)
            )
        }
        let payload = await withTaskCancellationHandler(
            operation: { await work.value },
            onCancel: { work.cancel() }
        )
        guard !Task.isCancelled, let payload else { return }
        gpxShareFile = GPXShareFile(data: payload.data, filename: payload.filename)
    }

    @MainActor
    private func renderImages() async {
        isRendering = true
        renderedCount = 0
        renderedImages = [:]
        await Task.yield()

        let dataSignature = currentDataSignature
        let aggregateTracks = await loadAggregateTracksIfNeeded()
        if Task.isCancelled { return }
        let snapshotSignature = aggregateTracks.map { "\(dataSignature)|aggregate:\($0.count)" }
            ?? "\(dataSignature)|live"
        let currentSnapshot: MovesShareSnapshot
        if snapshotDataSignature == snapshotSignature {
            currentSnapshot = snapshot
        } else {
            currentSnapshot = MovesShareSnapshot.make(
                from: dayTimelines,
                period: selectedPeriod,
                periodStart: selectedPeriodStart,
                aggregateTracks: aggregateTracks
            )
            snapshot = currentSnapshot
            snapshotDataSignature = snapshotSignature
        }
        let designs = availableDesigns(for: currentSnapshot)
        guard !designs.isEmpty else {
            isRendering = false
            renderedCount = 0
            renderedImages = [:]
            selectedDesigns = []
            return
        }

        var images: [MovesShareDesign: UIImage] = [:]
        for design in designs {
            if Task.isCancelled { return }
            var mapImage: UIImage? = nil
            var calendarMapImages: [String: UIImage] = [:]
            switch design {
            case .placeMap:
                mapImage = await MovesShareMapRenderer.render(
                    snapshot: currentSnapshot,
                    design: .places,
                    size: aspect.mapRenderSize,
                    mapStyle: mapStyle
                )
            case .tracks:
                mapImage = await MovesShareMapRenderer.render(
                    snapshot: currentSnapshot,
                    design: .tracks,
                    size: aspect.mapRenderSize,
                    mapStyle: mapStyle
                )
            case .heatMap:
                mapImage = await MovesShareMapRenderer.render(
                    snapshot: currentSnapshot,
                    design: .heatMap,
                    size: aspect.mapRenderSize,
                    mapStyle: mapStyle
                )
            case .calendar:
                let calendarMapSignature = [dataSignature, aspect.rawValue, mapStyle.rawValue]
                    .joined(separator: "|")
                if cachedCalendarMapSignature == calendarMapSignature {
                    calendarMapImages = cachedCalendarMapImages
                } else {
                    calendarMapImages = await MovesShareMapRenderer.renderCalendarDays(
                        currentSnapshot.calendarDays,
                        size: aspect.calendarMapRenderSize,
                        mapStyle: mapStyle
                    )
                    if Task.isCancelled { return }
                    cachedCalendarMapImages = calendarMapImages
                    cachedCalendarMapSignature = calendarMapSignature
                }
            case .overview, .places, .activeDays, .transport:
                mapImage = nil
            }
            if Task.isCancelled { return }
            let renderer = ImageRenderer(
                content: MovesShareCard(
                    snapshot: currentSnapshot,
                    design: design,
                    title: effectiveTitle,
                    background: background,
                    aspect: aspect,
                    mapImage: mapImage,
                    calendarMapImages: calendarMapImages
                )
            )
            renderer.scale = 1
            if let image = renderer.uiImage {
                images[design] = image
                renderedImages = images
            }
            renderedCount += 1
            await Task.yield()
        }

        selectedDesigns.formIntersection(Set(designs))
        isRendering = false
    }

    @MainActor
    private func loadAggregateTracksIfNeeded() async -> [ShareMapAggregateTrack]? {
        guard ShareMapAggregateStore.supports(selectedPeriod) else { return nil }

        func load() -> [ShareMapAggregateTrack]? {
            let cacheContext = ModelContext(modelContext.container)
            return ShareMapAggregateStore.cachedTracks(
                for: selectedPeriod,
                periodStart: selectedPeriodStart,
                timelines: selectedTimelines,
                in: cacheContext
            )
        }

        if let tracks = load() { return tracks }
        await ShareMapAggregateBuilder.refresh(
            period: selectedPeriod,
            periodStart: selectedPeriodStart,
            in: modelContext.container
        )
        if Task.isCancelled { return nil }
        return load()
    }
}

private struct MovesShareCustomizeView: View {
    @Binding var title: String
    @Binding var background: MovesShareBackground
    @Binding var aspect: MovesShareAspect
    @Binding var mapStyle: MovesShareMapStyle

    var body: some View {
        Form {
            Section("Share Image Title") {
                TextField("Title", text: $title)
                Button("Reset to Default") { title = "My Moves" }
            }

            Section("Aspect Ratio") {
                Picker("Aspect Ratio", selection: $aspect) {
                    ForEach(MovesShareAspect.allCases) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(MovesShareMapStyle.allCases) { option in
                    Button {
                        mapStyle = option
                    } label: {
                        Label(option.title, systemImage: option.symbolName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .trailing) {
                                if mapStyle == option {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(mapStyle == option ? Color.accentColor : Color.primary)
                }
            } header: {
                Text("Map Style")
            } footer: {
                Text("Used by Places Map, All Tracks, Heat Map, and Calendar.")
            }

            Section("Background") {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(MovesShareBackground.allCases) { option in
                        Button {
                            background = option
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                MovesShareBackgroundView(background: option)
                                    .frame(height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(
                                                background == option ? Color.accentColor : Color.secondary.opacity(0.25),
                                                lineWidth: background == option ? 3 : 1
                                            )
                                    }

                                Label(
                                    option.title,
                                    systemImage: background == option ? "checkmark.circle.fill" : "circle"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(background == option ? Color.accentColor : Color.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Customize")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MovesSharePreviewTile: View {
    let title: String
    let image: UIImage?
    let aspectRatio: CGFloat
    let isSelected: Bool
    let selectAction: () -> Void
    let shareAction: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: selectAction) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))

                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9), isSelected ? Color.accentColor : Color.black.opacity(0.35))
                        .padding(7)
                }
                .padding(7)
                .background(
                    isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2.5 : 1)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 2)

                Button(action: shareAction) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(image == nil)
                .accessibilityLabel("Share \(title)")
            }
            .padding(.horizontal, 3)
        }
    }
}

struct MovesActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct MovesShareBackgroundView: View {
    let background: MovesShareBackground

    var body: some View {
        switch background {
        case .moves:
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.16, blue: 0.18),
                    Color(red: 0.03, green: 0.32, blue: 0.29),
                    Color(red: 0.93, green: 0.40, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .sunrise:
            LinearGradient(
                colors: [
                    Color(red: 0.25, green: 0.08, blue: 0.30),
                    Color(red: 0.79, green: 0.20, blue: 0.28),
                    Color(red: 1.00, green: 0.68, blue: 0.25)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        case .midnight:
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.03, blue: 0.09),
                    Color(red: 0.04, green: 0.12, blue: 0.24),
                    Color(red: 0.14, green: 0.08, blue: 0.28)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .rainbow:
            LinearGradient(
                colors: [.pink, .orange, .yellow, .green, .cyan, .blue, .purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .light:
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.98, blue: 0.97),
                    Color(red: 0.88, green: 0.95, blue: 0.93),
                    Color(red: 1.00, green: 0.93, blue: 0.83)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private enum MovesShareMapDesign: Equatable {
    case places
    case tracks
    case heatMap
}

@MainActor
private enum MovesShareMapRenderer {
    static func render(
        snapshot: MovesShareSnapshot,
        design: MovesShareMapDesign,
        size: CGSize,
        mapStyle: MovesShareMapStyle
    ) async -> UIImage? {
        let coordinates: [CLLocationCoordinate2D]
        switch design {
        case .places:
            coordinates = snapshot.topPlaces.map(\.coordinate)
        case .tracks:
            coordinates = snapshot.tracks.flatMap { boundsCoordinates(for: $0) }
                + snapshot.topPlaces.map(\.coordinate)
        case .heatMap:
            coordinates = snapshot.heatTracks.flatMap { boundsCoordinates(for: $0.coordinates) }
                + snapshot.topPlaces.map(\.coordinate)
        }
        guard !coordinates.isEmpty else { return nil }

        var region = MapRegionFactory.region(for: coordinates)
        region.span.latitudeDelta = min(region.span.latitudeDelta * 1.25, 180)
        region.span.longitudeDelta = min(region.span.longitudeDelta * 1.25, 360)

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = 1
        options.mapType = mapStyle.mapType
        options.traitCollection = UITraitCollection(userInterfaceStyle: mapStyle.interfaceStyle)
        options.showsBuildings = mapStyle != .satellite
        options.pointOfInterestFilter = .excludingAll

        do {
            let mapSnapshot = try await MKMapSnapshotter(options: options).start()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return renderer.image { renderContext in
                mapSnapshot.image.draw(in: CGRect(origin: .zero, size: size))

                if design == .tracks {
                    drawTracks(snapshot.tracks, on: mapSnapshot, context: renderContext.cgContext)
                }
                if design == .heatMap {
                    drawHeatMap(
                        tracks: snapshot.heatTracks,
                        places: snapshot.topPlaces,
                        on: mapSnapshot,
                        context: renderContext.cgContext,
                        canvasSize: size
                    )
                } else {
                    drawPlaces(
                        snapshot.topPlaces,
                        on: mapSnapshot,
                        context: renderContext.cgContext,
                        showsLabels: design == .places,
                        canvasSize: size
                    )
                }
            }
        } catch {
            return nil
        }
    }

    static func renderCalendarDays(
        _ days: [MovesShareCalendarDay],
        size: CGSize,
        mapStyle: MovesShareMapStyle
    ) async -> [String: UIImage] {
        var images: [String: UIImage] = [:]

        for day in days {
            if Task.isCancelled { return images }
            if let image = await renderCalendarDay(day, size: size, mapStyle: mapStyle) {
                images[day.id] = image
            }
            await Task.yield()
        }

        return images
    }

    private static func renderCalendarDay(
        _ day: MovesShareCalendarDay,
        size: CGSize,
        mapStyle: MovesShareMapStyle
    ) async -> UIImage? {
        let coordinates = day.tracks.flatMap { boundsCoordinates(for: $0) }
            + day.placeCoordinates
        guard !coordinates.isEmpty else { return nil }

        var region = MapRegionFactory.region(for: coordinates)
        region.span.latitudeDelta = min(region.span.latitudeDelta * 1.4, 180)
        region.span.longitudeDelta = min(region.span.longitudeDelta * 1.4, 360)

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = 1
        options.mapType = mapStyle.mapType
        options.traitCollection = UITraitCollection(userInterfaceStyle: mapStyle.interfaceStyle)
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll

        do {
            let mapSnapshot = try await MKMapSnapshotter(options: options).start()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { renderContext in
                mapSnapshot.image.draw(in: CGRect(origin: .zero, size: size))
                drawCalendarTracks(day.tracks, on: mapSnapshot, context: renderContext.cgContext)
                drawCalendarPlaces(
                    day.placeCoordinates,
                    on: mapSnapshot,
                    context: renderContext.cgContext,
                    canvasSize: size
                )
            }
        } catch {
            return nil
        }
    }

    private static func boundsCoordinates(for track: MovesShareTrack) -> [CLLocationCoordinate2D] {
        boundsCoordinates(for: track.coordinates)
    }

    private static func boundsCoordinates(
        for coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first else { return [] }
        var north = first
        var south = first
        var east = first
        var west = first

        for coordinate in coordinates.dropFirst() {
            if coordinate.latitude > north.latitude { north = coordinate }
            if coordinate.latitude < south.latitude { south = coordinate }
            if coordinate.longitude > east.longitude { east = coordinate }
            if coordinate.longitude < west.longitude { west = coordinate }
        }
        return [north, south, east, west]
    }

    private enum HeatLayer: CaseIterable {
        case yellow
        case orange
        case red
    }

    private struct HeatPath {
        let path: CGPath
        let intensity: CGFloat
    }

    private struct HeatPoint {
        let point: CGPoint
        let intensity: CGFloat
    }

    private static func drawHeatMap(
        tracks: [MovesShareHeatTrack],
        places: [MovesSharePlace],
        on snapshot: MKMapSnapshotter.Snapshot,
        context: CGContext,
        canvasSize: CGSize
    ) {
        let maximumUsage = max(tracks.map(\.usageCount).max() ?? 1, 1)
        let paths = tracks
            .sorted(by: { $0.usageCount < $1.usageCount })
            .compactMap { track -> HeatPath? in
                guard track.coordinates.count > 1 else { return nil }
                let path = CGMutablePath()
                for (index, coordinate) in track.coordinates.enumerated() {
                    let point = snapshot.point(for: coordinate)
                    if index == 0
                        || RouteCoordinateOps.crossesAntimeridian(
                            from: track.coordinates[index - 1],
                            to: coordinate
                        ) {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                return HeatPath(
                    path: path,
                    intensity: MovesShareHeatScale.intensity(
                        frequency: track.usageCount,
                        maximum: maximumUsage
                    )
                )
            }

        let maximumVisits = max(places.map(\.visitCount).max() ?? 1, 1)
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let points = places
            .sorted(by: { $0.visitCount < $1.visitCount })
            .compactMap { place -> HeatPoint? in
                let point = snapshot.point(for: place.coordinate)
                guard canvas.insetBy(dx: -80, dy: -80).contains(point) else { return nil }
                return HeatPoint(
                    point: point,
                    intensity: MovesShareHeatScale.intensity(
                        frequency: place.visitCount,
                        maximum: maximumVisits
                    )
                )
            }

        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Composite the full heat map one color at a time. Drawing red last keeps
        // hot routes and places above every softer yellow/orange halo.
        for layer in HeatLayer.allCases {
            for path in paths {
                strokeHeatPath(path, layer: layer, context: context)
            }
            for point in points {
                drawHeatPoint(point, layer: layer, context: context)
            }
        }
    }

    private static func strokeHeatPath(
        _ heatPath: HeatPath,
        layer: HeatLayer,
        context: CGContext
    ) {
        let color: UIColor
        let width: CGFloat
        switch layer {
        case .yellow:
            color = .systemYellow.withAlphaComponent(0.24 - heatPath.intensity * 0.06)
            width = 36 + heatPath.intensity * 10
        case .orange:
            color = .systemOrange.withAlphaComponent(0.55 * pow(heatPath.intensity, 0.8))
            width = 19 + heatPath.intensity * 9
        case .red:
            color = .systemRed.withAlphaComponent(0.72 * pow(heatPath.intensity, 1.8))
            width = 5 + heatPath.intensity * 10
        }
        context.addPath(heatPath.path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokePath()
    }

    private static func drawHeatPoint(
        _ heatPoint: HeatPoint,
        layer: HeatLayer,
        context: CGContext
    ) {
        let color: UIColor
        let radiusScale: CGFloat
        switch layer {
        case .yellow:
            color = .systemYellow.withAlphaComponent(0.24 - heatPoint.intensity * 0.06)
            radiusScale = 1
        case .orange:
            color = .systemOrange.withAlphaComponent(0.62 * pow(heatPoint.intensity, 0.85))
            radiusScale = 0.64
        case .red:
            color = .systemRed.withAlphaComponent(0.78 * pow(heatPoint.intensity, 1.9))
            radiusScale = 0.34
        }
        let radius = (30 + heatPoint.intensity * 44) * radiusScale
        let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: heatPoint.point,
            startRadius: 0,
            endCenter: heatPoint.point,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
    }

    private static func drawTracks(
        _ tracks: [MovesShareTrack],
        on snapshot: MKMapSnapshotter.Snapshot,
        context: CGContext
    ) {
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for track in tracks where track.coordinates.count > 1 {
            let path = CGMutablePath()
            for (index, coordinate) in track.coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                if index == 0
                    || RouteCoordinateOps.crossesAntimeridian(
                        from: track.coordinates[index - 1],
                        to: coordinate
                    ) {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }

            context.addPath(path)
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.32).cgColor)
            context.setLineWidth(12)
            context.strokePath()

            context.addPath(path)
            context.setStrokeColor(trackColor(for: track.transportMode).cgColor)
            context.setLineWidth(7)
            context.strokePath()
        }
    }

    private static func drawCalendarTracks(
        _ tracks: [MovesShareTrack],
        on snapshot: MKMapSnapshotter.Snapshot,
        context: CGContext
    ) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for track in tracks where track.coordinates.count > 1 {
            let path = CGMutablePath()
            for (index, coordinate) in track.coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                if index == 0
                    || RouteCoordinateOps.crossesAntimeridian(
                        from: track.coordinates[index - 1],
                        to: coordinate
                    ) {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }

            context.addPath(path)
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.42).cgColor)
            context.setLineWidth(6)
            context.strokePath()

            context.addPath(path)
            context.setStrokeColor(trackColor(for: track.transportMode).cgColor)
            context.setLineWidth(3.5)
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func drawCalendarPlaces(
        _ coordinates: [CLLocationCoordinate2D],
        on snapshot: MKMapSnapshotter.Snapshot,
        context: CGContext,
        canvasSize: CGSize
    ) {
        let canvas = CGRect(origin: .zero, size: canvasSize)

        for coordinate in coordinates {
            let point = snapshot.point(for: coordinate)
            guard canvas.insetBy(dx: -8, dy: -8).contains(point) else { continue }
            context.setFillColor(UIColor.white.withAlphaComponent(0.96).cgColor)
            context.fillEllipse(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
            context.setFillColor(UIColor.systemOrange.cgColor)
            context.fillEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        }
    }

    private static func drawPlaces(
        _ places: [MovesSharePlace],
        on snapshot: MKMapSnapshotter.Snapshot,
        context: CGContext,
        showsLabels: Bool,
        canvasSize: CGSize
    ) {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let markerRadius: CGFloat = showsLabels ? 13 : 9

        for (index, place) in places.reversed().enumerated() {
            let point = snapshot.point(for: place.coordinate)
            guard canvas.insetBy(dx: -markerRadius, dy: -markerRadius).contains(point) else { continue }

            context.setFillColor(UIColor.white.withAlphaComponent(0.96).cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - markerRadius - 3,
                y: point.y - markerRadius - 3,
                width: (markerRadius + 3) * 2,
                height: (markerRadius + 3) * 2
            ))
            context.setFillColor(UIColor.systemOrange.cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - markerRadius,
                y: point.y - markerRadius,
                width: markerRadius * 2,
                height: markerRadius * 2
            ))

            let originalIndex = places.count - index - 1
            if showsLabels, originalIndex < 6 {
                drawLabel(place.title, near: point, in: canvas, context: context)
            }
        }
    }

    private static func drawLabel(
        _ text: String,
        near point: CGPoint,
        in canvas: CGRect,
        context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        let constrainedText = String(text.prefix(32))
        let textSize = (constrainedText as NSString).size(withAttributes: attributes)
        let labelSize = CGSize(width: textSize.width + 20, height: textSize.height + 12)
        var origin = CGPoint(x: point.x + 19, y: point.y - labelSize.height / 2)
        if origin.x + labelSize.width > canvas.maxX - 8 {
            origin.x = point.x - labelSize.width - 19
        }
        origin.y = min(max(origin.y, canvas.minY + 8), canvas.maxY - labelSize.height - 8)
        let labelRect = CGRect(origin: origin, size: labelSize)

        context.setFillColor(UIColor.systemBackground.withAlphaComponent(0.92).cgColor)
        context.addPath(UIBezierPath(roundedRect: labelRect, cornerRadius: 10).cgPath)
        context.fillPath()
        (constrainedText as NSString).draw(
            at: CGPoint(x: labelRect.minX + 10, y: labelRect.minY + 6),
            withAttributes: attributes
        )
    }

    private static func trackColor(for mode: TransportMode) -> UIColor {
        switch mode {
        case .stationary, .unknown: return .systemGray
        case .walking: return .systemGreen
        case .running: return .systemOrange
        case .swimming: return .systemCyan
        case .cycling: return .systemTeal
        case .automotive: return .systemBlue
        case .motorcycle: return .systemBlue
        case .train: return .systemPurple
        case .plane: return .systemIndigo
        case .boat: return .systemMint
        }
    }
}

private struct MovesShareCard: View {
    let snapshot: MovesShareSnapshot
    let design: MovesShareDesign
    let title: String
    let background: MovesShareBackground
    let aspect: MovesShareAspect
    let mapImage: UIImage?
    let calendarMapImages: [String: UIImage]

    private var primary: Color { background.isLight ? .black : .white }
    private var secondary: Color { primary.opacity(background.isLight ? 0.62 : 0.76) }
    private var scale: CGFloat {
        switch aspect {
        case .portrait: return 1
        case .square: return 0.76
        case .landscape: return 0.64
        }
    }
    private var padding: CGFloat { max(68 * scale, 42) }
    private var contentWidth: CGFloat { aspect.renderSize.width - padding * 2 }
    private var contentHeight: CGFloat { aspect.renderSize.height - padding * 2 }

    var body: some View {
        ZStack {
            MovesShareBackgroundView(background: background)

            VStack(alignment: .leading, spacing: scaled(36, minimum: 18)) {
                header

                Group {
                    switch design {
                    case .overview:
                        overviewContent
                    case .places:
                        placesContent
                    case .placeMap, .tracks, .heatMap:
                        mapContent
                    case .calendar:
                        calendarContent
                    case .activeDays:
                        activeDaysContent
                    case .transport:
                        transportContent
                    }
                }
                .frame(width: contentWidth)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .clipped()

                footer
            }
            .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        }
        .frame(width: aspect.renderSize.width, height: aspect.renderSize.height)
        .clipped()
        .foregroundStyle(primary)
    }

    private func scaled(_ value: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max(value * scale, minimum)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: scaled(22, minimum: 12)) {
            VStack(alignment: .leading, spacing: scaled(8, minimum: 5)) {
                Text(title)
                    .font(.system(size: scaled(68, minimum: 38), weight: .black, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)

                Text((design == .calendar ? snapshot.periodLabel : design.title).uppercased())
                    .font(.system(size: scaled(23, minimum: 14), weight: .bold, design: .rounded))
                    .tracking(scaled(2.2, minimum: 1.2))
                    .foregroundStyle(secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Image("M")
                .font(.system(size: scaled(48, minimum: 29), weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color("AccentColor"))
                .frame(width: scaled(82, minimum: 50), height: scaled(82, minimum: 50))
                .background(primary.opacity(0.15), in: Circle())
                .overlay { Circle().stroke(primary.opacity(0.22), lineWidth: 2) }
                .fixedSize()
        }
        .frame(width: contentWidth, alignment: .leading)
        .clipped()
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: scaled(34, minimum: 16)) {
            HStack(spacing: scaled(18, minimum: 10)) {
                metricTile(value: distanceText(snapshot.totalDistanceMeters), label: "distance")
                metricTile(value: "\(snapshot.uniquePlaceCount)", label: "places")
                metricTile(value: "\(snapshot.recordedDayCount)", label: "active days")
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: scaled(18, minimum: 10)
            ) {
                detailTile(symbol: "clock.fill", value: durationText(snapshot.totalMoveDuration), label: "moving")
                if snapshot.totalStepCount > 0 {
                    detailTile(symbol: "figure.walk", value: snapshot.totalStepCount.formatted(), label: "recorded steps")
                } else {
                    detailTile(symbol: "arrow.right", value: distanceText(snapshot.longestMoveMeters), label: "longest move")
                }
                detailTile(symbol: "arrow.triangle.swap", value: snapshot.moveCount.formatted(), label: "moves")
                detailTile(symbol: "mappin.and.ellipse", value: snapshot.visitCount.formatted(), label: "visits")
            }

            VStack(spacing: scaled(14, minimum: 8)) {
                if let place = snapshot.topPlaces.first {
                    highlightRow(
                        symbol: "heart.fill",
                        label: "Most visited",
                        value: place.title,
                        detail: "\(place.visitCount) visits"
                    )
                }
                if let day = snapshot.activeDays.first {
                    highlightRow(
                        symbol: "flame.fill",
                        label: "Most active",
                        value: day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
                        detail: distanceText(day.distanceMeters)
                    )
                }
                if let transport = snapshot.transports.first {
                    highlightRow(
                        symbol: transport.mode.symbolName,
                        label: "Top transport",
                        value: transport.mode.title,
                        detail: distanceText(transport.distanceMeters)
                    )
                }
            }
        }
    }

    private var placesContent: some View {
        let places = Array(snapshot.topPlaces.prefix(aspect == .landscape ? 5 : 7))
        let maximumVisits = max(places.first?.visitCount ?? 1, 1)

        return VStack(alignment: .leading, spacing: scaled(19, minimum: 10)) {
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                rankedBarRow(
                    rank: index + 1,
                    symbol: "mappin.circle.fill",
                    title: place.title,
                    value: "\(place.visitCount) \(place.visitCount == 1 ? "visit" : "visits")",
                    detail: "\(place.dayCount) \(place.dayCount == 1 ? "day" : "days") · \(durationText(place.totalDuration))",
                    progress: Double(place.visitCount) / Double(maximumVisits),
                    color: Color(red: 0.98, green: 0.50, blue: 0.24)
                )
            }
        }
    }

    private var activeDaysContent: some View {
        let days = Array(snapshot.activeDays.prefix(aspect == .landscape ? 5 : 7))
        let maximumScore = max(days.first?.activityScore ?? 1, 1)

        return VStack(alignment: .leading, spacing: scaled(19, minimum: 10)) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                rankedBarRow(
                    rank: index + 1,
                    symbol: "calendar",
                    title: day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year()),
                    value: distanceText(day.distanceMeters),
                    detail: "\(day.placeCount) places · \(day.moveCount) moves · \(durationText(day.moveDuration))",
                    progress: day.activityScore / maximumScore,
                    color: Color(red: 0.22, green: 0.85, blue: 0.68)
                )
            }
        }
    }

    private var transportContent: some View {
        let transports = Array(snapshot.transports.prefix(aspect == .landscape ? 5 : 7))
        let usesDistance = snapshot.totalDistanceMeters > 0
        let maximum = max(
            transports.map { usesDistance ? $0.distanceMeters : $0.duration }.max() ?? 1,
            1
        )

        return VStack(alignment: .leading, spacing: scaled(26, minimum: 13)) {
            HStack(spacing: scaled(18, minimum: 10)) {
                metricTile(value: distanceText(snapshot.totalDistanceMeters), label: "total distance")
                metricTile(value: durationText(snapshot.totalMoveDuration), label: "time moving")
                metricTile(value: snapshot.busiestWeekday ?? "–", label: "busiest weekday")
            }

            VStack(alignment: .leading, spacing: scaled(19, minimum: 10)) {
                ForEach(Array(transports.enumerated()), id: \.element.id) { index, transport in
                    rankedBarRow(
                        rank: index + 1,
                        symbol: transport.mode.symbolName,
                        title: transport.mode.title,
                        value: distanceText(transport.distanceMeters),
                        detail: "\(transport.segmentCount) segments · \(durationText(transport.duration))",
                        progress: (usesDistance ? transport.distanceMeters : transport.duration) / maximum,
                        color: MovesPalette.transport(transport.mode)
                    )
                }
            }
        }
    }

    private var mapContent: some View {
        Group {
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(primary.opacity(0.10))
                    .overlay {
                        Image(systemName: "map.fill")
                            .font(.system(size: scaled(90, minimum: 48), weight: .bold))
                            .foregroundStyle(secondary)
                    }
            }
        }
        .frame(width: contentWidth)
        .frame(maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: scaled(12, minimum: 8)) {
                if design == .placeMap {
                    mapStatPill(
                        symbol: "mappin.and.ellipse",
                        value: "\(snapshot.uniquePlaceCount) places"
                    )
                    mapStatPill(
                        symbol: "arrow.triangle.2.circlepath",
                        value: "\(snapshot.visitCount) visits"
                    )
                } else if design == .tracks {
                    mapStatPill(
                        symbol: "point.topleft.down.to.point.bottomright.curvepath",
                        value: "\(snapshot.tracks.count) tracks"
                    )
                    mapStatPill(
                        symbol: "arrow.left.and.right",
                        value: distanceText(snapshot.totalDistanceMeters)
                    )
                } else {
                    mapStatPill(
                        symbol: "flame.fill",
                        value: "\(snapshot.visitCount) visits"
                    )
                    mapStatPill(
                        symbol: "point.topleft.down.to.point.bottomright.curvepath",
                        value: "\(snapshot.moveCount) routes"
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .padding(.leading, scaled(30, minimum: 18))
            .padding(.bottom, scaled(30, minimum: 18))
        }
        .clipShape(RoundedRectangle(cornerRadius: scaled(30, minimum: 18), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: scaled(30, minimum: 18), style: .continuous)
                .stroke(.white.opacity(0.55), lineWidth: scaled(3, minimum: 2))
        }
    }

    private var calendarContent: some View {
        let calendar = Calendar.autoupdatingCurrent
        let monthDate = snapshot.calendarDays.first?.date ?? .now
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: monthDate)
        ) ?? monthDate
        let numberOfDays = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingDayCount = (firstWeekday - calendar.firstWeekday + 7) % 7
        let populatedSlotCount = leadingDayCount + numberOfDays
        let slotCount = max(((populatedSlotCount + 6) / 7) * 7, 35)
        let daysByNumber = Dictionary(
            uniqueKeysWithValues: snapshot.calendarDays.map {
                (calendar.component(.day, from: $0.date), $0)
            }
        )
        let weekdaySymbols = calendar.veryShortStandaloneWeekdaySymbols
        let orderedWeekdays = (0..<7).map {
            weekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7]
        }

        return VStack(spacing: calendarGridSpacing) {
            LazyVGrid(columns: calendarColumns, spacing: calendarGridSpacing) {
                ForEach(Array(orderedWeekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.uppercased())
                        .font(.system(size: scaled(17, minimum: 10), weight: .bold, design: .rounded))
                        .foregroundStyle(secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: calendarColumns, spacing: calendarGridSpacing) {
                ForEach(0..<slotCount, id: \.self) { slot in
                    let dayNumber = slot - leadingDayCount + 1
                    if dayNumber >= 1, dayNumber <= numberOfDays {
                        calendarDayCell(dayNumber: dayNumber, day: daysByNumber[dayNumber])
                    } else {
                        Color.clear
                            .frame(height: calendarCellHeight)
                    }
                }
            }
        }
        .frame(width: contentWidth, alignment: .top)
        .padding(.top, aspect == .portrait ? scaled(120) : scaled(18))
    }

    private var calendarColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: calendarGridSpacing),
            count: 7
        )
    }

    private var calendarGridSpacing: CGFloat {
        scaled(10, minimum: 6)
    }

    private var calendarCellHeight: CGFloat {
        switch aspect {
        case .portrait: return 174
        case .square: return 100
        case .landscape: return 104
        }
    }

    private func calendarDayCell(dayNumber: Int, day: MovesShareCalendarDay?) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: scaled(12, minimum: 7), style: .continuous)
                .fill(primary.opacity(day == nil ? 0.09 : 0.16))

            if let day, let image = calendarMapImages[day.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }

            if day != nil {
                LinearGradient(
                    colors: [.black.opacity(0.06), .black.opacity(0.12), .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            Text(dayNumber.formatted())
                .font(.system(size: scaled(20, minimum: 12), weight: .black, design: .rounded))
                .foregroundStyle(day == nil ? primary : .white)
                .shadow(color: day == nil ? .clear : .black.opacity(0.55), radius: 2, y: 1)
                .padding(scaled(10, minimum: 6))

            if day == nil {
                Text("No activity")
                    .font(.system(size: scaled(11, minimum: 7), weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(scaled(7, minimum: 4))
            } else if let day {
                VStack(alignment: .leading, spacing: scaled(3, minimum: 1)) {
                    Label(
                        "\(day.moveCount) \(day.moveCount == 1 ? "move" : "moves")",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                    Label(
                        "\(day.placeCount) \(day.placeCount == 1 ? "place" : "places")",
                        systemImage: "mappin"
                    )
                }
                .font(.system(size: scaled(12, minimum: 7), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(scaled(9, minimum: 5))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(height: calendarCellHeight)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: scaled(12, minimum: 7), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: scaled(12, minimum: 7), style: .continuous)
                .stroke(primary.opacity(0.16), lineWidth: 1)
        }
    }

    private func mapStatPill(symbol: String, value: String) -> some View {
        Label(value, systemImage: symbol)
            .font(.system(size: scaled(19, minimum: 12), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, scaled(17, minimum: 11))
            .padding(.vertical, scaled(11, minimum: 7))
            .background(.black.opacity(0.58), in: Capsule())
    }

    private func metricTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: scaled(5, minimum: 3)) {
            Text(value)
                .font(.system(size: scaled(42, minimum: 23), weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.58)
            Text(label.uppercased())
                .font(.system(size: scaled(16, minimum: 10), weight: .bold, design: .rounded))
                .tracking(scaled(1.2, minimum: 0.7))
                .foregroundStyle(secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(scaled(22, minimum: 13))
        .background(primary.opacity(background.isLight ? 0.10 : 0.13), in: RoundedRectangle(cornerRadius: scaled(24, minimum: 15)))
        .overlay {
            RoundedRectangle(cornerRadius: scaled(24, minimum: 15))
                .stroke(primary.opacity(0.15), lineWidth: 2)
        }
    }

    private func detailTile(symbol: String, value: String, label: String) -> some View {
        HStack(spacing: scaled(16, minimum: 9)) {
            Image(systemName: symbol)
                .font(.system(size: scaled(29, minimum: 18), weight: .bold))
                .frame(width: scaled(50, minimum: 30), height: scaled(50, minimum: 30))
                .background(primary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: scaled(2, minimum: 1)) {
                Text(value)
                    .font(.system(size: scaled(28, minimum: 17), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(label)
                    .font(.system(size: scaled(17, minimum: 11), weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(scaled(20, minimum: 12))
        .background(primary.opacity(background.isLight ? 0.08 : 0.10), in: RoundedRectangle(cornerRadius: scaled(20, minimum: 13)))
    }

    private func highlightRow(symbol: String, label: String, value: String, detail: String) -> some View {
        HStack(spacing: scaled(17, minimum: 10)) {
            Image(systemName: symbol)
                .font(.system(size: scaled(27, minimum: 17), weight: .bold))
                .frame(width: scaled(52, minimum: 32), height: scaled(52, minimum: 32))
                .background(primary.opacity(0.13), in: Circle())

            Text(label)
                .font(.system(size: scaled(18, minimum: 12), weight: .semibold, design: .rounded))
                .foregroundStyle(secondary)

            Spacer()

            VStack(alignment: .trailing, spacing: scaled(2, minimum: 1)) {
                Text(value)
                    .font(.system(size: scaled(23, minimum: 15), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(detail)
                    .font(.system(size: scaled(16, minimum: 10), weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, scaled(20, minimum: 12))
        .padding(.vertical, scaled(15, minimum: 9))
        .background(primary.opacity(background.isLight ? 0.08 : 0.10), in: RoundedRectangle(cornerRadius: scaled(20, minimum: 13)))
    }

    private func rankedBarRow(
        rank: Int,
        symbol: String,
        title: String,
        value: String,
        detail: String,
        progress: Double,
        color: Color
    ) -> some View {
        HStack(spacing: scaled(17, minimum: 10)) {
            Text("\(rank)")
                .font(.system(size: scaled(25, minimum: 16), weight: .black, design: .rounded))
                .frame(width: scaled(42, minimum: 26))

            Image(systemName: symbol)
                .font(.system(size: scaled(27, minimum: 17), weight: .bold))
                .frame(width: scaled(54, minimum: 33), height: scaled(54, minimum: 33))
                .background(color.opacity(background.isLight ? 0.20 : 0.28), in: Circle())

            VStack(alignment: .leading, spacing: scaled(8, minimum: 4)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: scaled(25, minimum: 16), weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Spacer(minLength: 12)
                    Text(value)
                        .font(.system(size: scaled(22, minimum: 14), weight: .bold, design: .rounded))
                        .lineLimit(1)
                }

                GeometryReader { geometry in
                    Capsule()
                        .fill(primary.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(color)
                                .frame(width: max(geometry.size.width * min(max(progress, 0), 1), scaled(10, minimum: 6)))
                        }
                }
                .frame(height: scaled(13, minimum: 8))

                Text(detail)
                    .font(.system(size: scaled(16, minimum: 10), weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, scaled(20, minimum: 12))
        .padding(.vertical, scaled(17, minimum: 9))
        .background(primary.opacity(background.isLight ? 0.08 : 0.10), in: RoundedRectangle(cornerRadius: scaled(22, minimum: 14)))
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(snapshot.periodLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Made with Moves")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: contentWidth)
        .clipped()
        .font(.system(size: scaled(18, minimum: 11), weight: .semibold, design: .rounded))
        .foregroundStyle(secondary)
    }

    private func distanceText(_ meters: CLLocationDistance) -> String {
        Measurement(value: max(meters, 0), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func durationText(_ duration: TimeInterval) -> String {
        DurationFormatter.text(for: duration)
    }
}
