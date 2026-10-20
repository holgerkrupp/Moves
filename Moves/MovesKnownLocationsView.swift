//
//  MovesKnownLocationsView.swift
//  Moves
//
//  Edit named locations and their individual proximity areas.
//

import CoreLocation
import Foundation
import MapKit
import SwiftData
import SwiftUI

private struct RegularPlaceSettingsQueryKey: Hashable {
    let definitions: [RegularPlaceDefinitionDTO]
    let historyRevision: Int
}

private struct RegularPlaceReconciliationRequest: Sendable {
    let location: RegularPlaceDefinitionDTO
    let replacedID: UUID?
    let previousDefinition: RegularPlaceDefinitionDTO?
    let definitions: [RegularPlaceDefinitionDTO]
    let selectedVisitID: UUID?
}

struct RegularPlacesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnownLocation.name, order: .forward) private var locations: [KnownLocation]
    @State private var isCreating = false
    @State private var visitCounts: [UUID: Int] = [:]
    @State private var frequentSummaries: [RegularPlaceSummaryDTO] = []
    @State private var legacyCandidates: [RegularPlaceVisitDTO] = []
    @State private var historyRevision = 0
    private var definitions: [RegularPlaceDefinitionDTO] { locations.map(RegularPlaceDefinitionDTO.init) }

    var body: some View {
        List {
            if locations.isEmpty {
                ContentUnavailableView("No Regular Places", systemImage: "mappin.and.ellipse", description: Text("Save places such as Home or Work to recognize future visits."))
            }
            if !locations.isEmpty { Section("Named Regular Places") {
            ForEach(locations) { location in
                NavigationLink {
                    KnownLocationEditorView(knownLocation: location, suggestedLocation: nil)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(location.name).font(.headline)
                            Spacer()
                            Text(KnownLocationFormatting.radius(location.radiusMeters)).font(.caption).foregroundStyle(.secondary)
                        }
                        let count = visitCounts[location.id]
                        Text("\(count.map { String($0) } ?? "…") matching visits · \(location.latitude.formatted(.number.precision(.fractionLength(3)))), \(location.longitude.formatted(.number.precision(.fractionLength(3))))")
                            .font(.caption).foregroundStyle(.secondary)
                        if locations.contains(where: { $0.id != location.id && location.distance(from: $0.coordinate) < location.radiusMeters + $0.radiusMeters }) {
                            Label("Overlaps another Regular Place", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            }}
            Section("Often Visited · Unnamed") {
                if frequentSummaries.isEmpty {
                    Text("Repeated visits without a name will appear here.").foregroundStyle(.secondary)
                } else {
                    ForEach(frequentSummaries) { summary in
                        NavigationLink {
                            KnownLocationEditorView(knownLocation: nil, suggestedLocation: summary)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(summary.title).font(.headline)
                                Text("\(summary.visitCount) visits · Save a name to make this a Regular Place")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }
            if !legacyCandidates.isEmpty {
                Section("Legacy labels to review") {
                    Text("These visits have a label matching a Regular Place name but are outside its saved radius. Keep labels that you assigned manually; remove only labels that were propagated by mistake.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(legacyCandidates) { visit in
                        HStack {
                            NavigationLink {
                                if let model = resolveVisit(visit.id) { PlaceMapDetailView(place: model) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(visit.userLabel ?? "Visit")
                                    Text(visit.arrivalDate, format: .dateTime.month().day().year())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button("Remove label", role: .destructive) {
                                if let model = resolveVisit(visit.id) {
                                    model.userLabel = nil
                                    try? modelContext.save()
                                    legacyCandidates.removeAll { $0.id == visit.id }
                                }
                            }.font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Regular Places")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Regular Place")
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                KnownLocationEditorView(knownLocation: nil, suggestedLocation: nil)
            }
        }
        .task(id: RegularPlaceSettingsQueryKey(definitions: definitions, historyRevision: historyRevision)) {
            await loadSummaries(for: definitions)
        }
        .onReceive(NotificationCenter.default.publisher(for: .movesVisitedPlaceDidChange)) { _ in
            visitCounts = [:]
            frequentSummaries = []
            legacyCandidates = []
            historyRevision += 1
        }
    }

    private func loadSummaries(for definitions: [RegularPlaceDefinitionDTO]) async {
        let worker = RegularPlaceQueryWorker(modelContainer: modelContext.container)
        do {
            async let summaries = worker.frequentUnnamedSummaries()
            async let counts = worker.counts(for: definitions)
            async let legacy = worker.legacyLabelCandidates(definitions: definitions, offset: 0, limit: 100)
            let result = try await (summaries, counts, legacy)
            guard !Task.isCancelled else { return }
            frequentSummaries = result.0
            visitCounts = Dictionary(uniqueKeysWithValues: result.1.map { ($0.regularPlaceID, $0.count) })
            legacyCandidates = result.2.visits
        } catch is CancellationError {
        } catch {
            // Saved Regular Place names remain visible when optional history summaries fail.
        }
    }

    private func resolveVisit(_ id: UUID) -> VisitPlace? {
        let predicate = #Predicate<VisitPlace> { $0.id == id }
        var descriptor = FetchDescriptor<VisitPlace>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}

struct KnownLocationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnownLocation.name, order: .forward) private var allKnownLocations: [KnownLocation]

    let knownLocation: KnownLocation?
    let suggestedLocation: RegularPlaceSummaryDTO?
    let selectedVisit: VisitPlace?
    let previousDefinition: RegularPlaceDefinitionDTO?

    @State private var draftName: String
    @State private var radiusMeters: Double
    @State private var centerLatitude: Double
    @State private var centerLongitude: Double
    @State private var camera: MapCameraPosition
    @State private var isConfirmingDeletion = false
    @State private var errorMessage = ""
    @State private var isShowingError = false
    @State private var matchingVisits: [RegularPlaceVisitDTO] = []
    @State private var isLoadingVisits = false
    @State private var visitsOffset = 0
    @State private var hasMoreVisits = false
    @State private var queryGeneration = UUID()
    @State private var isReconciling = false
    @State private var pendingDeletionID: UUID?
    @State private var pendingDeletionDefinitions: [RegularPlaceDefinitionDTO] = []
    @State private var pendingReconciliation: RegularPlaceReconciliationRequest?
    @State private var visitRevision = 0

    private var queryKey: String { "\(centerLatitude)|\(centerLongitude)|\(radiusMeters)" }

    init(
        knownLocation: KnownLocation?,
        suggestedLocation: RegularPlaceSummaryDTO?,
        selectedVisit: VisitPlace? = nil
    ) {
        self.knownLocation = knownLocation
        self.suggestedLocation = suggestedLocation
        self.selectedVisit = selectedVisit
        self.previousDefinition = knownLocation.map(RegularPlaceDefinitionDTO.init)

        let center: CLLocationCoordinate2D
        let initialRadius: Double
        if let knownLocation {
            center = knownLocation.coordinate
            initialRadius = knownLocation.radiusMeters
            _draftName = State(initialValue: knownLocation.name)
        } else if let selectedVisit {
            center = selectedVisit.coordinate
            initialRadius = 120
            _draftName = State(initialValue: selectedVisit.userLabel ?? selectedVisit.autoLabel ?? "")
        } else if let suggestedLocation {
            center = CLLocationCoordinate2D(latitude: suggestedLocation.latitude, longitude: suggestedLocation.longitude)
            initialRadius = 120
            _draftName = State(initialValue: suggestedLocation.title)
        } else {
            center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
            initialRadius = 120
            _draftName = State(initialValue: "")
        }

        _centerLatitude = State(initialValue: center.latitude)
        _centerLongitude = State(initialValue: center.longitude)
        _radiusMeters = State(initialValue: initialRadius)
        _camera = State(initialValue: .region(Self.region(center: center, radiusMeters: initialRadius)))
    }

    private var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                proximityMap(matchingVisits: matchingVisits)

                SettingsCard(title: knownLocation == nil ? "Create Regular Place" : "Regular Place Settings") {
                    TextField("Location name", text: $draftName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MovesPalette.textFieldBackground.opacity(0.92))
                        )

                    Text("Drag the map to reposition the center, or choose a recorded visit below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Proximity radius", systemImage: "circle.dashed")
                            Spacer()
                            Text(KnownLocationFormatting.radius(radiusMeters))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }

                        Slider(value: $radiusMeters, in: 25...2_000, step: 25)
                            .onChange(of: radiusMeters) { _, newValue in
                                camera = .region(Self.region(center: center, radiusMeters: newValue))
                            }

                        HStack(spacing: 8) {
                            ForEach([50.0, 120.0, 250.0, 500.0], id: \.self) { radius in
                                Button(KnownLocationFormatting.radius(radius)) {
                                    radiusMeters = radius
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    Label(
                        "\(matchingVisits.count) recorded visit\(matchingVisits.count == 1 ? "" : "s") on this page",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                    Button(isReconciling ? "Updating Visits…" : (knownLocation == nil ? "Create Regular Place" : "Save Changes")) {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || isReconciling)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                SettingsCard(title: "Location Visits") {
                    if matchingVisits.isEmpty {
                        Text("No recorded visits fall inside the current proximity circle.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matchingVisits) { visit in
                            HStack {
                                Button {
                                    centerLatitude = visit.latitude
                                    centerLongitude = visit.longitude
                                    camera = .region(Self.region(center: visit.coordinate, radiusMeters: radiusMeters))
                                } label: {
                                    KnownLocationVisitRow(visit: visit)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Use visit at \(visit.arrivalDate.formatted(date: .abbreviated, time: .shortened)) as Regular Place center")
                                NavigationLink {
                                    if let model = resolveVisit(visit.id) { PlaceMapDetailView(place: model) }
                                } label: {
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
                        }
                        if hasMoreVisits {
                            Button(isLoadingVisits ? "Loading…" : "Load More Visits") { Task { await loadMoreVisits() } }
                                .disabled(isLoadingVisits)
                        }
                    }
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
        .navigationTitle(knownLocation?.name ?? suggestedLocation?.title ?? "Regular Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if knownLocation != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        isConfirmingDeletion = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete Regular Place?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recorded visits remain in your timeline. Only the saved name and proximity area are removed.")
        }
        .alert(pendingReconciliation != nil || pendingDeletionID != nil ? "Could Not Update Visits" : "Could Not Save Location", isPresented: $isShowingError) {
            if pendingReconciliation != nil {
                Button("Retry Visit Updates") { Task { await retryReconciliation(container: nil) } }
            } else if pendingDeletionID != nil {
                Button("Retry Visit Updates") { Task { await reconcileDeletion() } }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .task(id: "\(queryKey)|\(visitRevision)") {
            let generation = UUID()
            queryGeneration = generation
            isLoadingVisits = false
            matchingVisits = []
            visitsOffset = 0
            hasMoreVisits = false
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            await loadMoreVisits(reset: true, generation: generation)
        }
        .onReceive(NotificationCenter.default.publisher(for: .movesVisitedPlaceDidChange)) { _ in
            matchingVisits = []
            visitsOffset = 0
            hasMoreVisits = false
            visitRevision += 1
        }
    }

    private func proximityMap(matchingVisits: [RegularPlaceVisitDTO]) -> some View {
        Map(position: $camera) {
            MapCircle(center: center, radius: radiusMeters)
                .foregroundStyle(MovesPalette.place.opacity(0.15))
                .stroke(MovesPalette.place, lineWidth: 2)

            Marker(trimmedName.isEmpty ? "Regular Place" : trimmedName, coordinate: center)
                .tint(MovesPalette.place)

            ForEach(matchingVisits.prefix(250)) { visit in
                Annotation(
                    visit.arrivalDate.formatted(date: .abbreviated, time: .omitted),
                    coordinate: visit.coordinate,
                    anchor: .center
                ) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle().stroke(MovesPalette.place, lineWidth: 2)
                        }
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let candidate = context.region.center
            guard CLLocationCoordinate2DIsValid(candidate) else { return }
            centerLatitude = candidate.latitude
            centerLongitude = candidate.longitude
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Label("Shaded circle is the recognized area", systemImage: "circle.dashed")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }

        let location: KnownLocation
        let originalID = knownLocation?.id
        if let knownLocation {
            location = knownLocation
            knownLocation.name = trimmedName
            knownLocation.radiusMeters = radiusMeters
            knownLocation.latitude = centerLatitude
            knownLocation.longitude = centerLongitude
            knownLocation.updatedAt = .now
        } else {
            location = KnownLocation(
                name: trimmedName,
                latitude: centerLatitude,
                longitude: centerLongitude,
                radiusMeters: radiusMeters
            )
            modelContext.insert(location)
        }

        do {
            try modelContext.save()
            let definitions = allKnownLocations.map(RegularPlaceDefinitionDTO.init)
            let definition = RegularPlaceDefinitionDTO(location)
            let container = modelContext.container
            pendingReconciliation = RegularPlaceReconciliationRequest(
                location: definition,
                replacedID: originalID,
                previousDefinition: previousDefinition,
                definitions: definitions,
                selectedVisitID: selectedVisit?.id
            )
            Task { await retryReconciliation(container: container) }
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    @MainActor
    private func retryReconciliation(container suppliedContainer: ModelContainer?) async {
        guard let request = pendingReconciliation else { return }
        isReconciling = true
        defer { isReconciling = false }
        do {
            let worker = RegularPlaceQueryWorker(modelContainer: suppliedContainer ?? modelContext.container)
            _ = try await worker.reconcile(location: request.location,
                                           replacedID: request.replacedID,
                                           previousDefinition: request.previousDefinition,
                                           definitions: request.definitions)
            if let selectedVisitID = request.selectedVisitID {
                let didAssign = try await worker.assignSelectedVisit(visitID: selectedVisitID, to: request.location)
                guard didAssign else {
                    errorMessage = "This visit’s location accuracy does not fit inside the Regular Place radius. Adjust the center or radius, then retry visit updates."
                    isShowingError = true
                    return
                }
            }
            pendingReconciliation = nil
            dismiss()
        } catch {
            errorMessage = "The Regular Place was saved, but its visits could not be updated: \(error.localizedDescription)"
            isShowingError = true
        }
    }

    private func delete() {
        guard let knownLocation else { return }
        let deletedID = knownLocation.id
        modelContext.delete(knownLocation)
        do {
            try modelContext.save()
            let definitions = allKnownLocations.filter { $0.id != deletedID }.map(RegularPlaceDefinitionDTO.init)
            pendingDeletionID = deletedID
            pendingDeletionDefinitions = definitions
            Task { await reconcileDeletion() }
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    @MainActor
    private func reconcileDeletion() async {
        guard let deletedID = pendingDeletionID else { return }
        isReconciling = true
        defer { isReconciling = false }
        do {
            let worker = RegularPlaceQueryWorker(modelContainer: modelContext.container)
            _ = try await worker.remove(locationID: deletedID, definitions: pendingDeletionDefinitions)
            pendingDeletionID = nil
            dismiss()
        } catch {
            errorMessage = "The Regular Place was deleted, but related visit classifications could not be updated: \(error.localizedDescription)"
            isShowingError = true
        }
    }

    private func loadMoreVisits(reset: Bool = false, generation requestedGeneration: UUID? = nil) async {
        let generation = requestedGeneration ?? queryGeneration
        guard generation == queryGeneration, reset || !isLoadingVisits else { return }
        isLoadingVisits = true
        defer { if generation == queryGeneration { isLoadingVisits = false } }
        let worker = RegularPlaceQueryWorker(modelContainer: modelContext.container)
        do {
            let page = try await worker.visits(
                nearLatitude: centerLatitude,
                longitude: centerLongitude,
                radiusMeters: radiusMeters,
                offset: reset ? 0 : visitsOffset,
                limit: 100
            )
            guard !Task.isCancelled, generation == queryGeneration else { return }
            if reset { matchingVisits = page.visits } else { matchingVisits.append(contentsOf: page.visits) }
            visitsOffset = page.nextOffset
            hasMoreVisits = page.hasMore
        } catch is CancellationError {
        } catch {
            guard generation == queryGeneration else { return }
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    private func resolveVisit(_ id: UUID) -> VisitPlace? {
        let predicate = #Predicate<VisitPlace> { $0.id == id }
        var descriptor = FetchDescriptor<VisitPlace>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private static func region(
        center: CLLocationCoordinate2D,
        radiusMeters: Double
    ) -> MKCoordinateRegion {
        let latitudeDelta = max(radiusMeters * 3.2 / 111_000, 0.003)
        let longitudeScale = max(cos(center.latitude * .pi / 180), 0.2)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: latitudeDelta / longitudeScale
            )
        )
    }
}

private struct KnownLocationVisitRow: View {
    let visit: RegularPlaceVisitDTO

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(MovesPalette.place)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(visit.arrivalDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(MovesStatisticsFormatting.duration(
                    max((visit.departureDate ?? .now).timeIntervalSince(visit.arrivalDate), 0)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}

enum KnownLocationLabeler {
    static func reconcile(
        location: KnownLocation,
        replacedID: UUID?,
        definitions: [KnownLocation],
        to visits: [VisitPlace]
    ) {
        let candidates = definitions.contains(where: { $0.id == location.id }) ? definitions : definitions + [location]
        for visit in visits {
            if visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                if visit.regularPlaceID == location.id { visit.regularPlaceName = location.name }
                continue
            }
            if visit.regularPlaceID == location.id || visit.regularPlaceID == replacedID {
                visit.regularPlaceID = nil
                visit.regularPlaceName = nil
            }
            if let match = RegularPlaceMatcher.match(coordinate: visit.coordinate,
                                                     accuracy: visit.horizontalAccuracy,
                                                     among: candidates) {
                visit.regularPlaceID = match.id
                visit.regularPlaceName = match.name
            }
        }
    }

}

private enum KnownLocationFormatting {
    static func radius(_ meters: Double) -> String {
        MovesMeasurementFormatter.distance(meters: meters)
    }
}
