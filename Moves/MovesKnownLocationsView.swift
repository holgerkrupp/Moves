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

struct RegularPlacesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnownLocation.name, order: .forward) private var locations: [KnownLocation]
    @Query private var visits: [VisitPlace]
    @State private var isCreating = false

    private var unlabeledFrequentLocations: [MovesLocationSummary] {
        let groups = Dictionary(grouping: visits.filter {
            ($0.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && ($0.regularPlaceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) { visit in
            "\(Int((visit.latitude * 1_000).rounded()))|\(Int((visit.longitude * 1_000).rounded()))"
        }
        return groups.values.filter { $0.count >= 2 }.map { group in
            let sorted = group.sorted { $0.arrivalDate > $1.arrivalDate }
            let duration = sorted.reduce(0.0) { total, visit in
                total + max((visit.departureDate ?? .now).timeIntervalSince(visit.arrivalDate), 0)
            }
            return MovesLocationSummary(id: "unlabeled:\(Int((sorted[0].latitude * 1_000).rounded()))|\(Int((sorted[0].longitude * 1_000).rounded()))",
                                        title: "\(sorted[0].latitude.formatted(.number.precision(.fractionLength(3)))), \(sorted[0].longitude.formatted(.number.precision(.fractionLength(3))))",
                                        visits: sorted, totalDuration: duration)
        }.sorted { $0.visitCount > $1.visitCount }
    }

    var body: some View {
        List {
            if locations.isEmpty {
                ContentUnavailableView("No Regular Places", systemImage: "mappin.and.ellipse", description: Text("Save places such as Home or Work to recognize future visits."))
            }
            if !locations.isEmpty { Section("Named Regular Places") {
            ForEach(locations) { location in
                NavigationLink {
                    KnownLocationEditorView(knownLocation: location, suggestedLocation: nil, allVisits: visits)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(location.name).font(.headline)
                            Spacer()
                            Text(KnownLocationFormatting.radius(location.radiusMeters)).font(.caption).foregroundStyle(.secondary)
                        }
                        let count = visits.filter { location.contains($0.coordinate) }.count
                        Text("\(count) matching visits · \(location.latitude.formatted(.number.precision(.fractionLength(3)))), \(location.longitude.formatted(.number.precision(.fractionLength(3))))")
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
                if unlabeledFrequentLocations.isEmpty {
                    Text("Repeated visits without a name will appear here.").foregroundStyle(.secondary)
                } else {
                    ForEach(unlabeledFrequentLocations) { summary in
                        NavigationLink {
                            KnownLocationEditorView(knownLocation: nil, suggestedLocation: summary, allVisits: visits)
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
                    ForEach(legacyCandidates, id: \.id) { visit in
                        HStack {
                            NavigationLink {
                                PlaceMapDetailView(place: visit)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(visit.userLabel ?? "Visit")
                                    Text(visit.arrivalDate, format: .dateTime.month().day().year())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button("Remove label", role: .destructive) {
                                visit.userLabel = nil
                                try? modelContext.save()
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
                KnownLocationEditorView(knownLocation: nil, suggestedLocation: nil, allVisits: visits)
            }
        }
    }

    private var legacyCandidates: [VisitPlace] {
        visits.filter { visit in
            visit.regularPlaceID == nil && locations.contains { location in
                visit.userLabel?.localizedCaseInsensitiveCompare(location.name) == .orderedSame
                    && !location.contains(visit.coordinate)
            }
        }.sorted { $0.arrivalDate > $1.arrivalDate }
    }
}

struct KnownLocationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnownLocation.name, order: .forward) private var allKnownLocations: [KnownLocation]

    let knownLocation: KnownLocation?
    let suggestedLocation: MovesLocationSummary?
    let selectedVisit: VisitPlace?
    let allVisits: [VisitPlace]
    private let visitsNewestFirst: [VisitPlace]

    @State private var draftName: String
    @State private var radiusMeters: Double
    @State private var centerLatitude: Double
    @State private var centerLongitude: Double
    @State private var camera: MapCameraPosition
    @State private var isConfirmingDeletion = false
    @State private var errorMessage = ""
    @State private var isShowingError = false

    init(
        knownLocation: KnownLocation?,
        suggestedLocation: MovesLocationSummary?,
        allVisits: [VisitPlace],
        selectedVisit: VisitPlace? = nil
    ) {
        self.knownLocation = knownLocation
        self.suggestedLocation = suggestedLocation
        self.selectedVisit = selectedVisit
        self.allVisits = allVisits
        self.visitsNewestFirst = allVisits.sorted { $0.arrivalDate > $1.arrivalDate }

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
            center = Self.suggestedCenter(for: suggestedLocation.visits)
            initialRadius = Self.suggestedRadius(for: suggestedLocation.visits, around: center)
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

    private var visitsInsideRadius: [VisitPlace] {
        let centerLocation = CLLocation(latitude: centerLatitude, longitude: centerLongitude)
        return visitsNewestFirst.filter { visit in
            centerLocation.distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude)) <= radiusMeters
        }
    }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let matchingVisits = visitsInsideRadius
        ScrollView {
            LazyVStack(spacing: 14) {
                proximityMap(matchingVisits: matchingVisits)

                SettingsCard(title: knownLocation == nil ? "Create Known Location" : "Location Settings") {
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
                        "\(matchingVisits.count) recorded visit\(matchingVisits.count == 1 ? "" : "s") inside this area",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                    Button(knownLocation == nil ? "Create Regular Place" : "Save Changes") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
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
                                    PlaceMapDetailView(place: visit)
                                } label: {
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
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
        .navigationTitle(knownLocation?.name ?? suggestedLocation?.title ?? "Location")
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
            "Delete Known Location?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recorded visits remain in your timeline. Only the saved name and proximity area are removed.")
        }
        .alert("Could Not Save Location", isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func proximityMap(matchingVisits: [VisitPlace]) -> some View {
        Map(position: $camera) {
            MapCircle(center: center, radius: radiusMeters)
                .foregroundStyle(MovesPalette.place.opacity(0.15))
                .stroke(MovesPalette.place, lineWidth: 2)

            Marker(trimmedName.isEmpty ? "Known location" : trimmedName, coordinate: center)
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

        KnownLocationLabeler.reconcile(location: location, replacedID: originalID, definitions: allKnownLocations, to: allVisits)

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    private func delete() {
        guard let knownLocation else { return }
        for visit in allVisits where visit.regularPlaceID == knownLocation.id {
            visit.regularPlaceID = nil
            visit.regularPlaceName = nil
            if let replacement = RegularPlaceMatcher.match(
                coordinate: visit.coordinate,
                accuracy: visit.horizontalAccuracy,
                among: allKnownLocations.filter { $0.id != knownLocation.id }
            ) {
                visit.regularPlaceID = replacement.id
                visit.regularPlaceName = replacement.name
            }
        }
        modelContext.delete(knownLocation)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    private static func suggestedCenter(for visits: [VisitPlace]) -> CLLocationCoordinate2D {
        guard !visits.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        let latitude = visits.reduce(0) { $0 + $1.latitude } / Double(visits.count)
        let longitude = visits.reduce(0) { $0 + $1.longitude } / Double(visits.count)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func suggestedRadius(
        for visits: [VisitPlace],
        around center: CLLocationCoordinate2D
    ) -> Double {
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let farthest = visits.map { visit in
            centerLocation.distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude))
                + max(visit.horizontalAccuracy, 0)
        }.max() ?? 120
        return min(max((farthest / 25).rounded(.up) * 25, 75), 1_000)
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
    let visit: VisitPlace

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
            if visit.regularPlaceID == location.id || visit.regularPlaceID == replacedID {
                visit.regularPlaceID = nil
                visit.regularPlaceName = nil
            }
            if let match = RegularPlaceMatcher.match(
                coordinate: visit.coordinate,
                accuracy: visit.horizontalAccuracy,
                among: candidates
            ), visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                if visit.regularPlaceID == nil {
                    visit.regularPlaceID = match.id
                    visit.regularPlaceName = match.name
                }
            }
        }
    }

}

private enum KnownLocationFormatting {
    static func radius(_ meters: Double) -> String {
        MovesMeasurementFormatter.distance(meters: meters)
    }
}
