//
//  MovesStatisticsSearchView.swift
//  Moves
//
//  Search and aggregate statistics for recorded places and journeys.
//

import Foundation
import SwiftData
import SwiftUI

struct MovesLocationSummary: Identifiable {
    let id: String
    let title: String
    let visits: [VisitPlace]
    let totalDuration: TimeInterval

    var visitCount: Int { visits.count }
    var averageDuration: TimeInterval { visits.isEmpty ? 0 : totalDuration / Double(visits.count) }
    var latestVisit: VisitPlace? { visits.max(by: { $0.arrivalDate < $1.arrivalDate }) }
}

struct MovesConnectionJourney: Identifiable {
    let legs: [MoveSegment]

    var id: String { legs.map { $0.id.uuidString }.joined(separator: "|") }
    var startDate: Date { legs.first?.timelineStartDate ?? .distantPast }
    var endDate: Date { legs.last?.endDate ?? startDate }
    var duration: TimeInterval { max(endDate.timeIntervalSince(startDate), 0) }
    var distanceMeters: Double { legs.reduce(0) { $0 + max($1.distanceMeters, 0) } }
    var isDirect: Bool { legs.count == 1 }
    var isExcludedFromStatistics: Bool {
        legs.first?.isExcludedFromConnectionStatistics == true
    }
    var originTitle: String { legs.first?.startPlace?.displayTitle ?? "Unknown place" }
    var destinationTitle: String { legs.last?.endPlace?.displayTitle ?? "Unknown place" }
}

struct MovesConnectionStatistics {
    let journeys: [MovesConnectionJourney]

    init(journeys: [MovesConnectionJourney]) {
        self.journeys = journeys.filter { !$0.isExcludedFromStatistics }
    }

    var minimumJourney: MovesConnectionJourney? {
        journeys.min { $0.duration < $1.duration }
    }

    var maximumJourney: MovesConnectionJourney? {
        journeys.max { $0.duration < $1.duration }
    }

    var minimumDuration: TimeInterval? { minimumJourney?.duration }
    var maximumDuration: TimeInterval? { maximumJourney?.duration }
    var averageDuration: TimeInterval? {
        guard !journeys.isEmpty else { return nil }
        return journeys.reduce(0) { $0 + $1.duration } / Double(journeys.count)
    }
}

struct MovesStatisticsSnapshot {
    let locations: [MovesLocationSummary]
    let visits: [VisitPlace]
    let moves: [MoveSegment]

    static let empty = MovesStatisticsSnapshot(locations: [], visits: [], moves: [])

    private init(locations: [MovesLocationSummary], visits: [VisitPlace], moves: [MoveSegment]) {
        self.locations = locations
        self.visits = visits
        self.moves = moves
    }

    init(dayTimelines: [DayTimeline], now: Date = .now) {
        var placesByID: [UUID: VisitPlace] = [:]
        var movesByID: [UUID: MoveSegment] = [:]

        for day in dayTimelines {
            for place in day.places {
                placesByID[place.id] = place
            }
            for move in day.moves {
                movesByID[move.id] = move
                if let startPlace = move.startPlace {
                    placesByID[startPlace.id] = startPlace
                }
                if let endPlace = move.endPlace {
                    placesByID[endPlace.id] = endPlace
                }
            }
        }

        let allVisits = placesByID.values.sorted { $0.arrivalDate > $1.arrivalDate }
        let groupedVisits = Dictionary(grouping: allVisits, by: Self.locationKey)

        locations = groupedVisits.map { key, grouped in
            let sortedVisits = grouped.sorted { $0.arrivalDate > $1.arrivalDate }
            let totalDuration = sortedVisits.reduce(0) { partial, visit in
                let departure = min(visit.departureDate ?? now, now)
                return partial + max(departure.timeIntervalSince(visit.arrivalDate), 0)
            }
            return MovesLocationSummary(
                id: key,
                title: sortedVisits.first?.displayTitle ?? "Unknown place",
                visits: sortedVisits,
                totalDuration: totalDuration
            )
        }
        .sorted {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            if $0.totalDuration != $1.totalDuration { return $0.totalDuration > $1.totalDuration }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        visits = allVisits
        moves = movesByID.values.sorted { $0.timelineStartDate < $1.timelineStartDate }
    }

    func filteredLocations(matching query: String) -> [MovesLocationSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return locations }
        return locations.filter { location in
            location.title.localizedCaseInsensitiveContains(query)
                || location.visits.contains { Self.visit($0, matches: query) }
        }
    }

    func filteredVisits(matching query: String) -> [VisitPlace] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visits }
        return visits.filter { Self.visit($0, matches: query) }
    }

    func journeys(
        from originKey: String,
        to destinationKey: String,
        includingIndirect: Bool,
        maximumIntermediateStop: TimeInterval = 12 * 60 * 60,
        maximumLegCount: Int = 8
    ) -> [MovesConnectionJourney] {
        guard originKey != destinationKey, maximumLegCount > 0 else { return [] }

        var results: [MovesConnectionJourney] = []
        for startIndex in moves.indices {
            let firstMove = moves[startIndex]
            guard Self.locationKey(firstMove.startPlace) == originKey else { continue }

            var legs = [firstMove]
            guard let firstDestination = Self.locationKey(firstMove.endPlace) else { continue }
            if firstDestination == destinationKey {
                results.append(MovesConnectionJourney(legs: legs))
                continue
            }
            guard includingIndirect else { continue }

            var currentLocationKey = firstDestination
            var nextIndex = moves.index(after: startIndex)
            while nextIndex < moves.endIndex, legs.count < maximumLegCount {
                let nextMove = moves[nextIndex]
                guard Self.locationKey(nextMove.startPlace) == currentLocationKey else { break }

                let stopDuration = nextMove.timelineStartDate.timeIntervalSince(legs.last?.endDate ?? nextMove.timelineStartDate)
                guard stopDuration >= -60, stopDuration <= maximumIntermediateStop else { break }

                legs.append(nextMove)
                guard let nextDestination = Self.locationKey(nextMove.endPlace) else { break }
                if nextDestination == destinationKey {
                    results.append(MovesConnectionJourney(legs: legs))
                    break
                }
                if nextDestination == originKey { break }

                currentLocationKey = nextDestination
                nextIndex = moves.index(after: nextIndex)
            }
        }

        var seen = Set<String>()
        return results
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.startDate > $1.startDate }
    }

    static func locationKey(_ place: VisitPlace) -> String {
        if let userLabel = normalized(place.userLabel) {
            return "user:\(userLabel)"
        }
        if let autoLabel = normalized(place.autoLabel) {
            return "auto:\(autoLabel)"
        }

        // Unnamed visits use roughly 100 m buckets. This absorbs normal GPS drift
        // while keeping nearby but distinct named places separate.
        let latitudeBucket = Int((place.latitude * 1_000).rounded())
        let longitudeBucket = Int((place.longitude * 1_000).rounded())
        return "coordinate:\(latitudeBucket)|\(longitudeBucket)"
    }

    static func locationKey(_ place: VisitPlace?) -> String? {
        place.map(locationKey)
    }

    private static func normalized(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func visit(_ visit: VisitPlace, matches query: String) -> Bool {
        if visit.displayTitle.localizedCaseInsensitiveContains(query) { return true }
        if visit.comment?.localizedCaseInsensitiveContains(query) == true { return true }

        let dateText = visit.arrivalDate.formatted(date: .long, time: .shortened)
        let numericDateText = visit.arrivalDate.formatted(date: .numeric, time: .shortened)
        return dateText.localizedCaseInsensitiveContains(query)
            || numericDateText.localizedCaseInsensitiveContains(query)
    }
}

struct MovesStatisticsSearchView: View {
    private enum Section: String, CaseIterable, Identifiable, Hashable {
        case overview = "Statistics"
        case visits = "Visits"
        case connections = "Connections"
        case createShare = "Create & Share"

        var id: String { rawValue }
    }

    private enum ConnectionEndpoint: String, Identifiable {
        case origin
        case destination

        var id: String { rawValue }
    }

    @Query(sort: \KnownLocation.name, order: .forward)
    private var knownLocations: [KnownLocation]

    private let dayTimelines: [DayTimeline]
    private let initialDate: Date
    @State private var snapshot: MovesStatisticsSnapshot
    @State private var isLoadingSnapshot = true

    @State private var visitSearchText = ""
    @State private var originKey: String?
    @State private var destinationKey: String?
    @State private var includesIndirectConnections = true
    @State private var includesReturnTrips = false
    @State private var endpointBeingSelected: ConnectionEndpoint?

    init(dayTimelines: [DayTimeline], initialDate: Date = .now) {
        self.dayTimelines = dayTimelines
        self.initialDate = initialDate
        _snapshot = State(initialValue: .empty)
    }

    var body: some View {
        compactWorkspace
        .sheet(item: $endpointBeingSelected) { endpoint in
            LocationSelectionView(
                title: endpoint == .origin ? "Choose Start" : "Choose Destination",
                locations: snapshot.locations,
                selection: endpoint == .origin ? $originKey : $destinationKey
            )
        }
        .onAppear(perform: selectCommuteDefaultsIfAvailable)
        .task {
            guard isLoadingSnapshot else { return }
            // Keep the navigation transition cheap. The full-history graph is assembled
            // after the destination is on screen; the next step is to replace this
            // compatibility path with the Sendable statistics worker as more detail
            // screens move to ID-based lookups.
            await Task.yield()
            snapshot = MovesStatisticsSnapshot(dayTimelines: dayTimelines)
            isLoadingSnapshot = false
            selectCommuteDefaultsIfAvailable()
        }
    }

    private var compactWorkspace: some View {
        List {
            SwiftUI.Section("Explore") {
                NavigationLink {
                    sectionContent(for: .overview)
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                NavigationLink {
                    sectionContent(for: .visits)
                } label: {
                    Label("Search Visits", systemImage: "magnifyingglass")
                }
                NavigationLink {
                    sectionContent(for: .connections)
                } label: {
                    Label("Connections", systemImage: "arrow.triangle.branch")
                }
            }

            SwiftUI.Section("Create & Share") {
                NavigationLink {
                    sectionContent(for: .createShare)
                } label: {
                    Label("Create & Share", systemImage: "square.and.arrow.up.on.square")
                }
            }
        }
        .navigationTitle("Statistics & Share")
    }

    @ViewBuilder
    private func sectionContent(for section: Section) -> some View {
        Group {
            switch section {
            case .overview:
                statisticsView
            case .visits:
                visitsView
            case .connections:
                connectionsView
            case .createShare:
                createShareView
            }
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle(section.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statisticsView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                SettingsCard(title: "Recorded History") {
                    HStack(spacing: 10) {
                        StatisticsMetric(title: "Visits", value: snapshot.visits.count.formatted())
                        StatisticsMetric(title: "Places", value: snapshot.locations.count.formatted())
                        StatisticsMetric(title: "Moves", value: snapshot.moves.count.formatted())
                    }
                }

                SettingsCard(title: "Most Visited Locations") {
                    if snapshot.locations.isEmpty {
                        ContentUnavailableView(
                            "No Visits Yet",
                            systemImage: "mappin.slash",
                            description: Text("Locations will appear here after Moves records visits.")
                        )
                    } else {
                        ForEach(Array(snapshot.locations.prefix(20).enumerated()), id: \.element.id) { index, location in
                            NavigationLink {
                                KnownLocationEditorView(
                                    knownLocation: knownLocation(for: location),
                                    suggestedLocation: location,
                                    allVisits: snapshot.visits
                                )
                            } label: {
                                LocationSummaryRow(location: location, rank: index + 1)
                            }
                            .buttonStyle(.plain)

                            if index < min(snapshot.locations.count, 20) - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
    }

    private var createShareView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                SettingsCard(title: "Create") {
                    NavigationLink {
                        MovesHistoryMapView(
                            dayTimelines: dayTimelines,
                            initialDate: initialDate
                        )
                    } label: {
                        createShareRow(
                            title: "History Map",
                            detail: "Explore every route and visit, then share the exact map framing.",
                            symbol: "map",
                            tint: MovesPalette.place
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(dayTimelines.allSatisfy { !$0.hasRecordedActivity })

                    Divider()

                    NavigationLink {
                        MovesShareGalleryView(
                            dayTimelines: dayTimelines,
                            initialDate: initialDate,
                            showsDismissButton: false
                        )
                    } label: {
                        createShareRow(
                            title: "Share Image Studio",
                            detail: "Build visual summaries, maps, and a calendar from a selected period.",
                            symbol: "photo.stack",
                            tint: MovesPalette.move
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(dayTimelines.allSatisfy { !$0.hasRecordedActivity })
                }

                SettingsCard(title: "Share") {
                    Label("Share Image Studio keeps the familiar image picker and multi-select share sheet.", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Label("History Map opens the same system share sheet after rendering the camera position you chose.", systemImage: "viewfinder")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "Choose a Starting Date") {
                    Text("Both tools open at \(initialDate, format: .dateTime.day().month(.abbreviated).year()). Choose another day or period inside the tool whenever you need it.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
    }

    private func createShareRow(
        title: String,
        detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }

    private var visitsView: some View {
        let locations = snapshot.filteredLocations(matching: visitSearchText)
        let visits = snapshot.filteredVisits(matching: visitSearchText)

        return ScrollView {
            LazyVStack(spacing: 14) {
                if visitSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SettingsCard(title: "Search Visits") {
                        Label("Search by place, note, or date", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text("Try a location such as Hamburg, a note, or a date from your history.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } else if locations.isEmpty && visits.isEmpty {
                    ContentUnavailableView.search(text: visitSearchText)
                        .panelSurface()
                } else {
                    if !locations.isEmpty {
                        SettingsCard(title: "Locations") {
                            ForEach(locations.prefix(20)) { location in
                                NavigationLink {
                                    KnownLocationEditorView(
                                        knownLocation: knownLocation(for: location),
                                        suggestedLocation: location,
                                        allVisits: snapshot.visits
                                    )
                                } label: {
                                    LocationSummaryRow(location: location, rank: nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !visits.isEmpty {
                        SettingsCard(title: "Visits") {
                            ForEach(visits.prefix(250)) { visit in
                                NavigationLink {
                                    PlaceMapDetailView(place: visit)
                                } label: {
                                    VisitSearchResultRow(place: visit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
        .searchable(text: $visitSearchText, prompt: "Location, note, or date")
    }

    private var connectionsView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                SettingsCard(title: "Find a Connection") {
                    ConnectionEndpointButton(
                        title: "From",
                        value: locationTitle(for: originKey),
                        systemImage: "circle.fill"
                    ) {
                        endpointBeingSelected = .origin
                    }

                    ConnectionEndpointButton(
                        title: "To",
                        value: locationTitle(for: destinationKey),
                        systemImage: "mappin.circle.fill"
                    ) {
                        endpointBeingSelected = .destination
                    }

                    HStack {
                        Button {
                            swap(&originKey, &destinationKey)
                        } label: {
                            Label("Swap", systemImage: "arrow.up.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(originKey == nil && destinationKey == nil)

                        Spacer()
                    }

                    Divider()

                    Toggle("Include indirect connections", isOn: $includesIndirectConnections)
                    Toggle("Include return trips", isOn: $includesReturnTrips)

                    Text("Indirect connections can include up to eight legs and stops of up to \(DurationFormatter.wideText(for: 12 * 60 * 60)). Turn on return trips to calculate two-way commute statistics.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                connectionResults
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
    }

    private func knownLocation(for summary: MovesLocationSummary) -> KnownLocation? {
        let candidates = knownLocations.compactMap {
            knownLocation -> (location: KnownLocation, matchingVisitCount: Int, nearestDistance: Double)? in
            let matchingVisits = summary.visits.filter { knownLocation.contains($0.coordinate) }
            guard !matchingVisits.isEmpty else { return nil }

            let nearestDistance = matchingVisits
                .map { knownLocation.distance(from: $0.coordinate) }
                .min() ?? .greatestFiniteMagnitude
            return (knownLocation, matchingVisits.count, nearestDistance)
        }

        return candidates.max { lhs, rhs in
            if lhs.matchingVisitCount != rhs.matchingVisitCount {
                return lhs.matchingVisitCount < rhs.matchingVisitCount
            }
            return lhs.nearestDistance > rhs.nearestDistance
        }?.location
    }

    @ViewBuilder
    private var connectionResults: some View {
        if let originKey, let destinationKey, originKey != destinationKey {
            let forward = snapshot.journeys(
                from: originKey,
                to: destinationKey,
                includingIndirect: includesIndirectConnections
            )
            let reverse = includesReturnTrips
                ? snapshot.journeys(
                    from: destinationKey,
                    to: originKey,
                    includingIndirect: includesIndirectConnections
                )
                : []
            let allJourneys = (forward + reverse).sorted { $0.startDate > $1.startDate }
            let statistics = MovesConnectionStatistics(journeys: allJourneys)
            let journeys = statistics.journeys
            let excludedJourneys = allJourneys.filter(\.isExcludedFromStatistics)

            if allJourneys.isEmpty {
                ContentUnavailableView(
                    "No Connections Found",
                    systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
                    description: Text("No matching recorded journey exists between these locations.")
                )
                .panelSurface()
            } else {
                if journeys.isEmpty {
                    SettingsCard(title: "Journey Times") {
                        Label("All matching journeys are excluded", systemImage: "chart.bar.xaxis")
                            .foregroundStyle(.secondary)
                        Text("Include a journey below to use it in the minimum, average, and maximum calculations again.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SettingsCard(title: "Journey Times") {
                        Text("\(journeys.count) included journey\(journeys.count == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            if let minimumJourney = statistics.minimumJourney {
                                JourneyStatisticLink(title: "Minimum", journey: minimumJourney)
                            }
                            StatisticsMetric(
                                title: "Average",
                                value: MovesStatisticsFormatting.duration(statistics.averageDuration)
                            )
                            if let maximumJourney = statistics.maximumJourney {
                                JourneyStatisticLink(title: "Maximum", journey: maximumJourney)
                            }
                        }
                    }

                    SettingsCard(title: "Matching Journeys") {
                        ForEach(journeys) { journey in
                            NavigationLink {
                                ConnectionJourneyDetailView(journey: journey)
                            } label: {
                                ConnectionJourneyRow(journey: journey)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !excludedJourneys.isEmpty {
                    SettingsCard(title: "Excluded Journeys") {
                        Text("These journeys remain in your timeline but do not affect commute statistics.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        ForEach(excludedJourneys) { journey in
                            NavigationLink {
                                ConnectionJourneyDetailView(journey: journey)
                            } label: {
                                ConnectionJourneyRow(journey: journey, isExcluded: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else {
            SettingsCard(title: "Connection Search") {
                Label("Choose two different locations", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text("You will see when you traveled between them, plus minimum, average, and maximum journey times.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func locationTitle(for key: String?) -> String? {
        guard let key else { return nil }
        return snapshot.locations.first(where: { $0.id == key })?.title
    }

    private func selectCommuteDefaultsIfAvailable() {
        guard originKey == nil, destinationKey == nil else { return }
        let homeNames = ["home", "zuhause"]
        let workNames = ["work", "office", "arbeit", "büro"]
        originKey = snapshot.locations.first { location in
            homeNames.contains { location.title.localizedCaseInsensitiveContains($0) }
        }?.id
        destinationKey = snapshot.locations.first { location in
            workNames.contains { location.title.localizedCaseInsensitiveContains($0) }
        }?.id
    }
}

private struct StatisticsMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct JourneyStatisticLink: View {
    let title: String
    let journey: MovesConnectionJourney

    var body: some View {
        NavigationLink {
            ConnectionJourneyDetailView(journey: journey)
        } label: {
            StatisticsMetric(
                title: title,
                value: MovesStatisticsFormatting.duration(journey.duration)
            )
            .foregroundStyle(.primary)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct LocationSummaryRow: View {
    let location: MovesLocationSummary
    let rank: Int?

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text(rank.formatted())
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            Image(systemName: "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(MovesPalette.place)

            VStack(alignment: .leading, spacing: 3) {
                Text(location.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(location.visitCount) visit\(location.visitCount == 1 ? "" : "s") · \(MovesStatisticsFormatting.duration(location.totalDuration)) total")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}

private struct VisitSearchResultRow: View {
    let place: VisitPlace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(MovesPalette.place)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.displayTitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(MovesStatisticsFormatting.visitInterval(place))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                if let comment = place.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

private struct ConnectionEndpointButton: View {
    let title: String
    let value: String?
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(MovesPalette.move)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value ?? "Choose location")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

private struct ConnectionJourneyRow: View {
    let journey: MovesConnectionJourney
    var isExcluded = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: journey.isDirect ? "arrow.right.circle.fill" : "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(MovesPalette.move)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(journey.originTitle) → \(journey.destinationTitle)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(journey.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(MovesStatisticsFormatting.duration(journey.duration)) · \(MovesStatisticsFormatting.distance(journey.distanceMeters)) · \(journey.isDirect ? "Direct" : "\(journey.legs.count) legs")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            if isExcluded {
                Image(systemName: "chart.bar.xaxis")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

private struct LocationSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let locations: [MovesLocationSummary]
    @Binding var selection: String?
    @State private var searchText = ""

    private var filteredLocations: [MovesLocationSummary] {
        guard !searchText.isEmpty else { return locations }
        return locations.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filteredLocations) { location in
                Button {
                    selection = location.id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(location.title)
                                .foregroundStyle(.primary)
                            Text("\(location.visitCount) visit\(location.visitCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == location.id {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                        }
                    }
                }
            }
            .overlay {
                if filteredLocations.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: "Search locations")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct ConnectionJourneyDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let journey: MovesConnectionJourney

    @State private var errorMessage = ""
    @State private var isShowingError = false

    private var isExcluded: Bool {
        journey.isExcludedFromStatistics
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                SettingsCard(title: "Journey") {
                    Text("\(journey.originTitle) → \(journey.destinationTitle)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(journey.startDate.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        StatisticsMetric(title: "Time", value: MovesStatisticsFormatting.duration(journey.duration))
                        StatisticsMetric(title: "Distance", value: MovesStatisticsFormatting.distance(journey.distanceMeters))
                        StatisticsMetric(title: "Legs", value: journey.legs.count.formatted())
                    }
                }

                SettingsCard(title: "Route Legs") {
                    ForEach(journey.legs) { leg in
                        NavigationLink {
                            MoveMapDetailView(segment: leg)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: leg.transportMode.symbolName)
                                    .foregroundStyle(MovesPalette.move)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(leg.startPlace?.displayTitle ?? "Unknown") → \(leg.endPlace?.displayTitle ?? "Unknown")")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.primary)
                                    Text("\(MovesStatisticsFormatting.duration(leg.timelineDuration)) · \(MovesStatisticsFormatting.distance(leg.distanceMeters)) · \(leg.transportMode.title)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }

                SettingsCard(title: "Statistics") {
                    if isExcluded {
                        Label("Excluded from commute calculations", systemImage: "chart.bar.xaxis")
                            .foregroundStyle(.secondary)
                        Text("This journey still appears in your timeline and can be included again at any time.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("If this journey is an inaccurate outlier, exclude it from minimum, average, and maximum commute times without deleting it.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        setExcluded(!isExcluded)
                    } label: {
                        Label(
                            isExcluded ? "Include in Calculations" : "Exclude from Calculations",
                            systemImage: isExcluded ? "chart.bar.fill" : "chart.bar.xaxis"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(isExcluded ? MovesPalette.move : .red)
                }
            }
            .padding(14)
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Could Not Update Statistics", isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func setExcluded(_ excluded: Bool) {
        guard let firstLeg = journey.legs.first else { return }
        firstLeg.isExcludedFromConnectionStatistics = excluded

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }
}

enum MovesStatisticsFormatting {
    static func duration(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else { return "—" }
        return DurationFormatter.extendedText(for: value)
    }

    static func distance(_ meters: Double) -> String {
        MovesMeasurementFormatter.distance(meters: meters)
    }

    static func visitInterval(_ place: VisitPlace) -> String {
        let arrival = place.arrivalDate.formatted(date: .abbreviated, time: .shortened)
        guard let departure = place.departureDate else { return "Since \(arrival)" }
        return "\(arrival) · \(duration(departure.timeIntervalSince(place.arrivalDate)))"
    }
}
