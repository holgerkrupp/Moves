//
//  MovesDetailViews.swift
//  Raul
//
//  Place and move detail screens extracted from ContentView.
//

import Foundation
import MapKit
import SwiftData
import SwiftUI

struct PlaceMapDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var place: VisitPlace

    @State private var camera: MapCameraPosition
    @State private var draftLabel: String

    init(place: VisitPlace) {
        self.place = place
        _draftLabel = State(initialValue: place.userLabel ?? place.autoLabel ?? "")
        _camera = State(initialValue: .region(
            MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        ))
    }

    var body: some View {
        Map(position: $camera) {
            Marker(place.displayTitle, coordinate: place.coordinate)
                .tint(MovesPalette.place)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .navigationTitle("Place")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(place.displayTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Arrived \(place.arrivalDate, format: .dateTime.hour().minute())")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.75))

                if let autoLabel = place.autoLabel,
                   (place.userLabel?.isEmpty ?? true) {
                    Text("Auto-detected: \(autoLabel)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    TextField("Label (Home, Work...)", text: $draftLabel)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MovesPalette.textFieldBackground.opacity(0.92))
                        )
                        .onSubmit(saveLabel)

                    Button("Save") {
                        saveLabel()
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    QuickLabelButton(label: "Home") {
                        draftLabel = "Home"
                        saveLabel()
                    }
                    QuickLabelButton(label: "Work") {
                        draftLabel = "Work"
                        saveLabel()
                    }
                    QuickLabelButton(label: "Gym") {
                        draftLabel = "Gym"
                        saveLabel()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .panelSurface()
            .padding(12)
        }
    }

    private func saveLabel() {
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            place.userLabel = nil
        } else {
            place.userLabel = trimmed
            place.autoLabel = nil
        }

        do {
            try modelContext.save()
        } catch {
            print("Failed to save place label: \(error.localizedDescription)")
        }
    }
}

struct QuickLabelButton: View {
    let label: String
    var action: () -> Void

    var body: some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
    }
}

struct MoveMapDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var segment: MoveSegment

    @State private var camera: MapCameraPosition
    @State private var routeCoordinates: [CLLocationCoordinate2D]

    private var routeRefreshKey: String {
        let start = Int(segment.timelineStartDate.timeIntervalSince1970.rounded())
        let end = Int(segment.endDate.timeIntervalSince1970.rounded())
        let sampleKey = segment.samples.map { sample in
            "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
        }
        .joined(separator: ",")

        return "\(segment.id.uuidString)|\(segment.transportMode.rawValue)|\(start)|\(end)|\(sampleKey)"
    }

    init(segment: MoveSegment) {
        self.segment = segment
        let all = MoveRouteGeometry.rawCoordinates(for: segment)
        let signature = MoveRouteGeometry.cacheSignature(for: segment, fallback: all)
        let initialRoute = segment.cachedRouteCoordinates(for: signature) ?? all

        _camera = State(initialValue: .region(MapRegionFactory.region(for: initialRoute)))
        _routeCoordinates = State(initialValue: initialRoute)
    }

    var body: some View {
        Map(position: $camera) {
            if let start = segment.startPlace?.coordinate {
                Marker("Start", coordinate: start)
                    .tint(MovesPalette.place)
            }

            if routeCoordinates.count > 1 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(segment.routeDisplayTint, lineWidth: 5)
            }

            if let end = segment.endPlace?.coordinate {
                Marker("End", coordinate: end)
                    .tint(.red)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .navigationTitle("Move")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Transport mode", selection: transportBucketSelection) {
                    Image(systemName: DayTransportBucket.walking.symbolName)
                        .tag(DayTransportBucket.walking)
                    Image(systemName: DayTransportBucket.cycling.symbolName)
                        .tag(DayTransportBucket.cycling)
                    Image(systemName: DayTransportBucket.automotive.symbolName)
                        .tag(DayTransportBucket.automotive)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 156)
            }
        }
        .task(id: routeRefreshKey) {
            routeCoordinates = await RoadRouteMatcher.matchedCoordinates(for: segment)
            if modelContext.hasChanges {
                do {
                    try modelContext.save()
                } catch {
                    print("Failed to persist matched route cache: \(error.localizedDescription)")
                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(moveRouteTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(segment.transportMode.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("\(DurationFormatter.text(for: segment.timelineDuration))   \(Measurement(value: max(segment.distanceMeters, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .panelSurface()
            .padding(12)
        }
    }

    private var moveRouteTitle: String {
        let start = segment.startPlace?.displayTitle ?? "Unknown start"
        let end = segment.endPlace?.displayTitle ?? "Unknown destination"
        return "\(start) to \(end)"
    }

    private var transportBucketSelection: Binding<DayTransportBucket> {
        Binding(
            get: { DayTransportBucket(segment.transportMode) ?? .walking },
            set: { newBucket in
                let newMode = newBucket.transportMode
                guard segment.transportMode != newMode else { return }

                let previousMode = segment.transportMode
                segment.transportMode = newMode

                do {
                    try modelContext.save()
                } catch {
                    segment.transportMode = previousMode
                    print("Failed to save move transport mode: \(error.localizedDescription)")
                }
            }
        )
    }
}
