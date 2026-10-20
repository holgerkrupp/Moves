import CoreLocation
import Foundation
import SwiftData
import SwiftUI

/// A paginated history of visits associated with the same physical place.
/// The view only passes Sendable values to the background query worker.
struct OtherVisitsAtPlaceView: View {
    private let reference: RegularPlaceVisitDTO
    private let regularPlace: RegularPlaceDefinitionDTO?

    @Environment(\.modelContext) private var modelContext
    @State private var visits: [RegularPlaceVisitDTO] = []
    @State private var bufferedVisits: [RegularPlaceVisitDTO] = []
    @State private var queryOffset = 0
    @State private var queryHasMore = true
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var loadError: String?
    @State private var refreshID = UUID()
    @State private var loadGeneration = UUID()

    private let pageSize = 30

    private var queryDefinition: RegularPlaceDefinitionDTO? {
        if let regularPlace { return regularPlace }
        guard let id = reference.regularPlaceID else { return nil }
        return RegularPlaceDefinitionDTO(
            id: id,
            name: reference.regularPlaceName ?? "Regular Place",
            latitude: reference.latitude,
            longitude: reference.longitude,
            radiusMeters: OtherVisitsMatcher.fallbackRadius(for: reference)
        )
    }

    init(reference: RegularPlaceVisitDTO, regularPlace: RegularPlaceDefinitionDTO? = nil) {
        self.reference = reference
        self.regularPlace = regularPlace
    }

    var body: some View {
        List {
            if visits.isEmpty, isLoading {
                ProgressView("Loading visits…")
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            } else if visits.isEmpty, let loadError {
                ContentUnavailableView {
                    Label("Couldn’t Load Visits", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await loadNextPage() } }
                }
                .listRowSeparator(.hidden)
            } else if visits.isEmpty, didLoad {
                ContentUnavailableView("No Other Visits", systemImage: "mappin.and.ellipse", description: Text("No other recorded visits match this place."))
                    .listRowSeparator(.hidden)
            } else {
                ForEach(visits) { visit in
                    NavigationLink {
                        VisitPlaceByIDView(id: visit.id)
                    } label: {
                        OtherVisitRow(visit: visit)
                    }
                    .accessibilityIdentifier("otherVisit-\(visit.id.uuidString)")
                }

                if let loadError {
                    HStack {
                        Text(loadError).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { Task { await loadNextPage() } }
                    }
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if hasMore {
                    Button("Load More Visits") { Task { await loadNextPage() } }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Other Visits")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(reference.id.uuidString):\(refreshID.uuidString)") {
            resetResults()
            await loadNextPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .movesVisitedPlaceDidChange)) { _ in
            resetResults()
            refreshID = UUID()
        }
    }

    private var hasMore: Bool { queryHasMore || !bufferedVisits.isEmpty }

    private func resetResults() {
        visits = []
        bufferedVisits = []
        queryOffset = 0
        queryHasMore = true
        didLoad = false
        loadError = nil
        isLoading = false
        loadGeneration = UUID()
    }

    @MainActor
    private func loadNextPage() async {
        guard !isLoading, hasMore || !didLoad else { return }
        isLoading = true
        let generation = loadGeneration
        loadError = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
                didLoad = true
            }
        }

        do {
            // Fill a complete visible page. Saved places use the worker's single
            // globally ordered query for identity matches plus unclassified
            // historical visits inside the place boundary.
            while bufferedVisits.count < pageSize && queryHasMore {
                try Task.checkCancellation()
                let worker = RegularPlaceQueryWorker(modelContainer: modelContext.container)
                let page = try await fetchPage(using: worker)
                try Task.checkCancellation()
                guard generation == loadGeneration else { return }

                queryOffset = page.nextOffset
                queryHasMore = page.hasMore
                let candidates = bufferedVisits + page.visits
                bufferedVisits = OtherVisitsMatcher.matchingVisits(
                    candidates,
                    reference: reference,
                    regularPlace: queryDefinition
                )
            }

            let next = Array(bufferedVisits.prefix(pageSize))
            bufferedVisits.removeFirst(next.count)
            visits.append(contentsOf: next)
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func fetchPage(using worker: RegularPlaceQueryWorker) async throws -> RegularPlacePage {
        if let definition = queryDefinition {
            guard isValid(definition) else {
                return try await worker.visits(regularPlaceID: definition.id, offset: queryOffset, limit: pageSize)
            }
            return try await worker.historyVisits(
                regularPlaceID: definition.id,
                definition: definition,
                offset: queryOffset,
                limit: pageSize
            )
        }
        guard isValid(reference) else {
            return RegularPlacePage(visits: [], nextOffset: queryOffset, hasMore: false)
        }
        return try await worker.visits(
            nearLatitude: reference.latitude,
            longitude: reference.longitude,
            radiusMeters: OtherVisitsMatcher.fallbackRadius(for: reference),
            offset: queryOffset,
            limit: pageSize
        )
    }

    private func isValid(_ visit: RegularPlaceVisitDTO) -> Bool {
        visit.latitude.isFinite && (-90...90).contains(visit.latitude)
            && visit.longitude.isFinite && (-180...180).contains(visit.longitude)
            && visit.horizontalAccuracy.isFinite && visit.horizontalAccuracy >= 0
    }

    private func isValid(_ definition: RegularPlaceDefinitionDTO) -> Bool {
        definition.latitude.isFinite && (-90...90).contains(definition.latitude)
            && definition.longitude.isFinite && (-180...180).contains(definition.longitude)
            && definition.radiusMeters.isFinite && definition.radiusMeters >= 0
    }
}

/// Pure matching and ordering rules, kept independent from SwiftData for tests.
enum OtherVisitsMatcher {
    static func fallbackRadius(for reference: RegularPlaceVisitDTO) -> Double {
        // A conservative base radius accommodates ordinary GPS drift while the
        // accuracy-aware post-filter below prevents a broad uncertainty circle
        // from matching a clearly separate location.
        100
    }

    static func matchingVisits(
        _ candidates: [RegularPlaceVisitDTO],
        reference: RegularPlaceVisitDTO,
        regularPlace: RegularPlaceDefinitionDTO?
    ) -> [RegularPlaceVisitDTO] {
        var byID: [UUID: RegularPlaceVisitDTO] = [:]
        let placeID = regularPlace?.id ?? reference.regularPlaceID
        let center = CLLocation(latitude: regularPlace?.latitude ?? reference.latitude, longitude: regularPlace?.longitude ?? reference.longitude)
        let radius = regularPlace?.radiusMeters ?? fallbackRadius(for: reference)

        for candidate in candidates where candidate.id != reference.id {
            let isSameIdentity = placeID != nil && candidate.regularPlaceID == placeID
            let isUnclassified = candidate.regularPlaceID == nil
            let candidateLocation = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
            let distance = center.distance(from: candidateLocation)
            let uncertainty = max(0, candidate.horizontalAccuracy)
            // Keep the full uncertainty disk within the target area. Very poor
            // fixes therefore cannot pull a distant visit into the group.
            let hasValidSpatialFix = candidate.latitude.isFinite
                && candidate.longitude.isFinite
                && candidate.horizontalAccuracy.isFinite
                && candidate.horizontalAccuracy >= 0
            let isSpatiallyClose = hasValidSpatialFix && distance + uncertainty <= radius

            guard isSameIdentity || (isUnclassified && isSpatiallyClose) else { continue }
            if let existing = byID[candidate.id] {
                // Deterministically keep the duplicate representation with the
                // stronger location accuracy.
                if candidate.horizontalAccuracy < existing.horizontalAccuracy {
                    byID[candidate.id] = candidate
                }
            } else {
                byID[candidate.id] = candidate
            }
        }

        return byID.values.sorted(by: newestFirst)
    }

    static func newestFirst(_ lhs: RegularPlaceVisitDTO, _ rhs: RegularPlaceVisitDTO) -> Bool {
        if lhs.arrivalDate != rhs.arrivalDate { return lhs.arrivalDate > rhs.arrivalDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct OtherVisitRow: View {
    let visit: RegularPlaceVisitDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(visit.userLabel ?? visit.regularPlaceName ?? visit.autoLabel ?? "Visit")
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(visit.arrivalDate.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(durationText)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var durationText: String {
        guard let departureDate = visit.departureDate else { return "Duration unavailable" }
        let duration = max(0, departureDate.timeIntervalSince(visit.arrivalDate))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3_600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "Duration unavailable"
    }
}

/// Resolve the live SwiftData model on the UI context at navigation time.
/// No actor-owned model is passed through the query service or kept in this list.
private struct VisitPlaceByIDView: View {
    let id: UUID
    @Query private var matches: [VisitPlace]

    init(id: UUID) {
        self.id = id
        _matches = Query(filter: #Predicate<VisitPlace> { $0.id == id })
    }

    var body: some View {
        if let place = matches.first {
            PlaceMapDetailView(place: place)
        } else {
            ContentUnavailableView("Visit Unavailable", systemImage: "mappin.slash", description: Text("This visit may have been deleted or changed on another device."))
        }
    }
}
