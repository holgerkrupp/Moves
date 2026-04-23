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
    @EnvironmentObject private var undoController: AppUndoController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var place: VisitPlace
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false

    @State private var camera: MapCameraPosition
    @State private var draftLabel: String
    @State private var isConfirmingDeletion = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage = ""
    @State private var isShowingDeleteError = false

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
            if showsBigMarkers {
                Marker(place.displayTitle, coordinate: place.coordinate)
                    .tint(MovesPalette.place)
            } else {
                Annotation(place.displayTitle, coordinate: place.coordinate, anchor: .center) {
                    MapLocationDot(tint: MovesPalette.place)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .navigationTitle("Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    isConfirmingDeletion = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(isDeleting)
            }
        }
        .confirmationDialog(
            "Delete Place?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deletePlace()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes this place from the timeline. You can undo the deletion afterwards.")
        }
        .alert("Could Not Delete Place", isPresented: $isShowingDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
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

    private func deletePlace() {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        let undoPayload = DeletedPlaceUndoPayload(place: place)
        let undoManager = undoController.manager

        modelContext.delete(place)
        do {
            try modelContext.save()
            undoManager.registerUndo(withTarget: modelContext) { context in
                undoPayload.restore(in: context)
            }
            undoManager.setActionName("Delete Place")
            dismiss()
        } catch {
            modelContext.rollback()
            deleteErrorMessage = error.localizedDescription
            isShowingDeleteError = true
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
    @EnvironmentObject private var undoController: AppUndoController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var segment: MoveSegment
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false

    @State private var camera: MapCameraPosition
    @State private var routeCoordinates: [CLLocationCoordinate2D]
    @State private var isConfirmingDeletion = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage = ""
    @State private var isShowingDeleteError = false

    private var activeRenderedRoute: RenderedRoute {
        RenderedRoute(
            id: segment.id.uuidString,
            coordinates: routeCoordinates,
            usesHighAccuracyRouteTracking: segment.usesHighAccuracyRouteTracking,
            transportMode: segment.transportMode
        )
    }

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
                if showsBigMarkers {
                    Marker("Start", coordinate: start)
                        .tint(MovesPalette.place)
                } else {
                    Annotation("Start", coordinate: start, anchor: .center) {
                        MapLocationDot(tint: MovesPalette.place)
                    }
                }
            }

            if activeRenderedRoute.shadowCoordinates.count > 1 {
                MapPolyline(coordinates: activeRenderedRoute.shadowCoordinates)
                    .stroke(activeRenderedRoute.shadowTint, lineWidth: activeRenderedRoute.shadowLineWidth)
            }

            if activeRenderedRoute.coordinates.count > 1 {
                MapPolyline(coordinates: activeRenderedRoute.coordinates)
                    .stroke(activeRenderedRoute.tint, lineWidth: activeRenderedRoute.lineWidth)
            }

            if let end = segment.endPlace?.coordinate {
                if showsBigMarkers {
                    Marker("End", coordinate: end)
                        .tint(.red)
                } else {
                    Annotation("End", coordinate: end, anchor: .center) {
                        MapLocationDot(tint: .red)
                    }
                }
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
                    Image(systemName: DayTransportBucket.train.symbolName)
                        .tag(DayTransportBucket.train)
                    Image(systemName: DayTransportBucket.plane.symbolName)
                        .tag(DayTransportBucket.plane)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 248)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    isConfirmingDeletion = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(isDeleting)
            }
        }
        .confirmationDialog(
            "Delete Move?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteMove()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes this move from the timeline. You can undo the deletion afterwards.")
        }
        .alert("Could Not Delete Move", isPresented: $isShowingDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
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

    private func deleteMove() {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        let undoPayload = DeletedMoveUndoPayload(segment: segment)
        let undoManager = undoController.manager

        modelContext.delete(segment)
        do {
            try modelContext.save()
            undoManager.registerUndo(withTarget: modelContext) { context in
                undoPayload.restore(in: context)
            }
            undoManager.setActionName("Delete Move")
            dismiss()
        } catch {
            modelContext.rollback()
            deleteErrorMessage = error.localizedDescription
            isShowingDeleteError = true
        }
    }
}

private struct DeletedPlaceUndoPayload {
    let id: UUID
    let arrivalDate: Date
    let departureDate: Date?
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let userLabel: String?
    let autoLabel: String?
    let createdAt: Date
    let dayTimeline: DayTimeline?
    let outgoingMoves: [MoveSegment]
    let incomingMoves: [MoveSegment]

    init(place: VisitPlace) {
        id = place.id
        arrivalDate = place.arrivalDate
        departureDate = place.departureDate
        latitude = place.latitude
        longitude = place.longitude
        horizontalAccuracy = place.horizontalAccuracy
        userLabel = place.userLabel
        autoLabel = place.autoLabel
        createdAt = place.createdAt
        dayTimeline = place.dayTimeline
        outgoingMoves = place.outgoingMoves
        incomingMoves = place.incomingMoves
    }

    @MainActor
    func restore(in context: ModelContext) {
        guard !containsPlace(with: id, in: context) else { return }

        let restored = VisitPlace(
            arrivalDate: arrivalDate,
            departureDate: departureDate,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            userLabel: userLabel,
            autoLabel: autoLabel
        )
        restored.id = id
        restored.createdAt = createdAt
        restored.dayTimeline = dayTimeline
        context.insert(restored)

        for move in outgoingMoves {
            move.startPlace = restored
        }
        for move in incomingMoves {
            move.endPlace = restored
        }
    }

    private func containsPlace(with id: UUID, in context: ModelContext) -> Bool {
        do {
            return try context.fetch(FetchDescriptor<VisitPlace>()).contains { $0.id == id }
        } catch {
            print("Failed to inspect place undo state: \(error.localizedDescription)")
            return false
        }
    }
}

private struct DeletedMoveUndoPayload {
    let id: UUID
    let dedupeKey: String
    let startDate: Date
    let endDate: Date
    let transportMode: TransportMode
    let distanceMeters: Double
    let stepCount: Int?
    let createdAt: Date
    let startPlace: VisitPlace?
    let endPlace: VisitPlace?
    let dayTimeline: DayTimeline?
    let routeCacheSignature: String?
    let routeCacheCoordinatesData: Data?
    let samples: [LocationSample]

    init(segment: MoveSegment) {
        id = segment.id
        dedupeKey = segment.dedupeKey
        startDate = segment.startDate
        endDate = segment.endDate
        transportMode = segment.transportMode
        distanceMeters = segment.distanceMeters
        stepCount = segment.stepCount
        createdAt = segment.createdAt
        startPlace = segment.startPlace
        endPlace = segment.endPlace
        dayTimeline = segment.dayTimeline
        routeCacheSignature = segment.routeCacheSignature
        routeCacheCoordinatesData = segment.routeCacheCoordinatesData
        samples = segment.samples
    }

    @MainActor
    func restore(in context: ModelContext) {
        guard !containsMove(with: id, in: context) else { return }

        let restored = MoveSegment(
            dedupeKey: dedupeKey,
            startDate: startDate,
            endDate: endDate,
            transportMode: transportMode,
            distanceMeters: distanceMeters,
            stepCount: stepCount
        )
        restored.id = id
        restored.createdAt = createdAt
        restored.startPlace = startPlace
        restored.endPlace = endPlace
        restored.dayTimeline = dayTimeline
        restored.routeCacheSignature = routeCacheSignature
        restored.routeCacheCoordinatesData = routeCacheCoordinatesData
        context.insert(restored)

        for sample in samples {
            sample.moveSegment = restored
        }
    }

    private func containsMove(with id: UUID, in context: ModelContext) -> Bool {
        do {
            return try context.fetch(FetchDescriptor<MoveSegment>()).contains { $0.id == id }
        } catch {
            print("Failed to inspect move undo state: \(error.localizedDescription)")
            return false
        }
    }
}
