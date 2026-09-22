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

struct KnownLocationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let knownLocation: KnownLocation?
    let suggestedLocation: MovesLocationSummary?
    let allVisits: [VisitPlace]

    private let centerLatitude: Double
    private let centerLongitude: Double

    @State private var draftName: String
    @State private var radiusMeters: Double
    @State private var camera: MapCameraPosition
    @State private var isConfirmingDeletion = false
    @State private var errorMessage = ""
    @State private var isShowingError = false

    init(
        knownLocation: KnownLocation?,
        suggestedLocation: MovesLocationSummary?,
        allVisits: [VisitPlace]
    ) {
        self.knownLocation = knownLocation
        self.suggestedLocation = suggestedLocation
        self.allVisits = allVisits

        let center: CLLocationCoordinate2D
        let initialRadius: Double
        if let knownLocation {
            center = knownLocation.coordinate
            initialRadius = knownLocation.radiusMeters
            _draftName = State(initialValue: knownLocation.name)
        } else if let suggestedLocation {
            center = Self.suggestedCenter(for: suggestedLocation.visits)
            initialRadius = Self.suggestedRadius(for: suggestedLocation.visits, around: center)
            _draftName = State(initialValue: suggestedLocation.title)
        } else {
            center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
            initialRadius = 120
            _draftName = State(initialValue: "")
        }

        centerLatitude = center.latitude
        centerLongitude = center.longitude
        _radiusMeters = State(initialValue: initialRadius)
        _camera = State(initialValue: .region(Self.region(center: center, radiusMeters: initialRadius)))
    }

    private var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    private var matchingVisits: [VisitPlace] {
        let centerLocation = CLLocation(latitude: centerLatitude, longitude: centerLongitude)
        return allVisits
            .filter { visit in
                centerLocation.distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude)) <= radiusMeters
            }
            .sorted { $0.arrivalDate > $1.arrivalDate }
    }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                proximityMap

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

                    Button(knownLocation == nil ? "Create Location" : "Save Changes") {
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
                            NavigationLink {
                                PlaceMapDetailView(place: visit)
                            } label: {
                                KnownLocationVisitRow(visit: visit)
                            }
                            .buttonStyle(.plain)
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

    private var proximityMap: some View {
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
        let previousName: String?
        if let knownLocation {
            location = knownLocation
            previousName = knownLocation.name
            knownLocation.name = trimmedName
            knownLocation.radiusMeters = radiusMeters
            knownLocation.updatedAt = .now
        } else {
            location = KnownLocation(
                name: trimmedName,
                latitude: centerLatitude,
                longitude: centerLongitude,
                radiusMeters: radiusMeters
            )
            previousName = suggestedLocation?.title
            modelContext.insert(location)
        }

        KnownLocationLabeler.apply(
            location: location,
            previousName: previousName,
            to: allVisits
        )

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
    static func apply(
        location: KnownLocation,
        previousName: String?,
        to visits: [VisitPlace]
    ) {
        let oldName = previousName?.trimmingCharacters(in: .whitespacesAndNewlines)
        for visit in visits where location.contains(visit.coordinate) {
            let currentLabel = visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentLabel?.isEmpty != false
                || currentLabel?.localizedCaseInsensitiveCompare(oldName ?? "") == .orderedSame
                || currentLabel?.localizedCaseInsensitiveCompare(location.name) == .orderedSame {
                visit.userLabel = location.name
            }
        }
    }
}

private enum KnownLocationFormatting {
    static func radius(_ meters: Double) -> String {
        MovesMeasurementFormatter.distance(meters: meters)
    }
}
