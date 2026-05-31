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
    @Environment(\.openURL) private var openURL
    @Bindable var segment: MoveSegment
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false

    @State private var camera: MapCameraPosition
    @State private var routeCoordinates: [CLLocationCoordinate2D]
    @State private var isShowingTransportPicker = false
    @State private var isEditingManualRoute = false
    @State private var manualRouteDrag: ManualRouteDragState?
    @State private var routeBeforeManualDrag: [CLLocationCoordinate2D] = []
    @State private var liveManualRouteMatchTask: Task<Void, Never>?
    @State private var manualRouteDragRevision = 0
    @State private var isIgnoringCurrentManualRouteGesture = false
    @State private var isSavingManualRoute = false
    @State private var isConfirmingDeletion = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage = ""
    @State private var isShowingDeleteError = false
    @State private var isShowingHealthOpenError = false

    private var activeRenderedRoute: RenderedRoute {
        RenderedRoute(
            id: segment.id.uuidString,
            coordinates: routeCoordinates,
            usesHighAccuracyRouteTracking: segment.usesHighAccuracyRouteTracking,
            usesHealthWorkoutRoute: segment.usesHealthWorkoutRoute,
            transportMode: segment.transportMode
        )
    }

    private var routeRefreshKey: String {
        let start = Int(segment.timelineStartDate.timeIntervalSince1970.rounded())
        let end = Int(segment.endDate.timeIntervalSince1970.rounded())
        let sampleKey = segment.samples
            .sorted(by: { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                if lhs.dedupeKey != rhs.dedupeKey { return lhs.dedupeKey < rhs.dedupeKey }
                if lhs.sourceRawValue != rhs.sourceRawValue { return lhs.sourceRawValue < rhs.sourceRawValue }
                if lhs.latitude != rhs.latitude { return lhs.latitude < rhs.latitude }
                return lhs.longitude < rhs.longitude
            })
            .map { sample in
                "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
            }
            .joined(separator: ",")

        return "\(segment.id.uuidString)|\(segment.transportMode.rawValue)|\(start)|\(end)|\(sampleKey)"
    }

    init(segment: MoveSegment) {
        self.segment = segment
        let all = MoveRouteGeometry.rawCoordinates(for: segment)
        let signature = MoveRouteGeometry.cacheSignature(for: segment, fallback: all)
        let initialRoute = segment.manualRouteCoordinates ?? segment.cachedRouteCoordinates(for: signature) ?? all

        _camera = State(initialValue: .region(MapRegionFactory.region(for: initialRoute)))
        _routeCoordinates = State(initialValue: initialRoute)
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: mapInteractionModes) {
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
            .simultaneousGesture(manualRouteEditGesture(proxy: proxy))
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .navigationTitle("Move")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    isShowingTransportPicker = true
                } label: {
                    Image(systemName: segment.transportMode.symbolName)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .glassEffect(in: Circle())
                }
                .buttonStyle(.glass)
                .popover(isPresented: $isShowingTransportPicker, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                    transportModePickerContent
                }
                .help("Transport mode")
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    if segment.usesHealthWorkoutRoute {
                        Button {
                            openAppleHealth()
                        } label: {
                            Label("Open in Apple Health", systemImage: "heart.text.square")
                                .labelStyle(.iconOnly)
                        }
                        .help("Open in Apple Health")
                    }

                    Button {
                        isEditingManualRoute.toggle()
                        manualRouteDrag = nil
                        isIgnoringCurrentManualRouteGesture = false
                        liveManualRouteMatchTask?.cancel()
                        liveManualRouteMatchTask = nil
                    } label: {
                        Image(systemName: isEditingManualRoute ? "hand.draw.fill" : "hand.draw")
                    }
                    .disabled(routeCoordinates.count < 2 || isSavingManualRoute)
                    .help(isEditingManualRoute ? "Stop editing route" : "Edit route")

                    Button(role: .destructive) {
                        isConfirmingDeletion = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(isDeleting)
                }
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
        .alert("Could Not Open Apple Health", isPresented: $isShowingHealthOpenError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Apple Health could not be opened from this device.")
        }
        .task(id: routeRefreshKey) {
            await refreshRouteCoordinates()
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(moveRouteTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(segment.transportMode.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                if segment.usesHealthWorkoutRoute {
                    Label("Apple Health route", systemImage: "heart.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(MovesPalette.healthRoute)
                }
                if segment.hasManualRouteCoordinates {
                    HStack(spacing: 10) {
                        Label("Manual route", systemImage: "hand.draw.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(activeRenderedRoute.tint)

                        Button {
                            revertManualRoute()
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(isSavingManualRoute)
                    }
                } else if isEditingManualRoute {
                    Label("Drag the route line to adjust it", systemImage: "hand.draw")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(activeRenderedRoute.tint)
                }
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

    private func openAppleHealth() {
        guard let url = URL(string: "x-apple-health://") else { return }
        openURL(url) { accepted in
            if !accepted {
                isShowingHealthOpenError = true
            }
        }
    }

    private var moveRouteTitle: String {
        let start = segment.startPlace?.displayTitle ?? "Unknown start"
        let end = segment.endPlace?.displayTitle ?? "Unknown destination"
        return "\(start) to \(end)"
    }

    private var mapInteractionModes: MapInteractionModes {
        isEditingManualRoute && manualRouteDrag != nil ? [.zoom] : [.pan, .zoom]
    }

    private func manualRouteEditGesture(proxy: MapProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                updateManualRouteDrag(at: value.location, proxy: proxy)
            }
            .onEnded { value in
                finishManualRouteDrag(at: value.location, proxy: proxy)
            }
    }

    private var transportModePickerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transport mode")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ForEach(DayTransportBucket.allCases, id: \.self) { bucket in
                Button {
                    updateTransportBucket(to: bucket)
                    isShowingTransportPicker = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: bucket.symbolName)
                            .foregroundStyle(bucket.tint)
                            .frame(width: 20)

                        Text(bucket.title)
                            .foregroundStyle(.primary)

                        Spacer()

                        if segment.transportMode == bucket.transportMode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(bucket.tint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 12)
        .frame(minWidth: 220)
        .presentationCompactAdaptation(.popover)
    }

    private func updateTransportBucket(to newBucket: DayTransportBucket) {
        let newMode = newBucket.transportMode
        guard segment.transportMode != newMode else { return }

        let previousMode = segment.transportMode
        let previousRouteCacheSignature = segment.routeCacheSignature
        let previousRouteCacheCoordinatesData = segment.routeCacheCoordinatesData
        let previousManualRouteCoordinatesData = segment.manualRouteCoordinatesData
        segment.transportMode = newMode
        segment.clearCachedRouteCoordinates()
        segment.clearManualRouteCoordinates()
        routeCoordinates = MoveRouteGeometry.rawCoordinates(for: segment)

        do {
            try modelContext.save()
            Task { @MainActor in
                await refreshRouteCoordinates()
            }
        } catch {
            segment.transportMode = previousMode
            segment.routeCacheSignature = previousRouteCacheSignature
            segment.routeCacheCoordinatesData = previousRouteCacheCoordinatesData
            segment.manualRouteCoordinatesData = previousManualRouteCoordinatesData
            print("Failed to save move transport mode: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func refreshRouteCoordinates() async {
        routeCoordinates = await RoadRouteMatcher.matchedCoordinates(for: segment)
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                print("Failed to persist matched route cache: \(error.localizedDescription)")
            }
        }
    }

    private func updateManualRouteDrag(at point: CGPoint, proxy: MapProxy) {
        guard isEditingManualRoute, routeCoordinates.count > 1 else { return }
        guard !isIgnoringCurrentManualRouteGesture else { return }

        if manualRouteDrag == nil {
            guard let nearest = nearestRoutePoint(to: point, proxy: proxy),
                  nearest.distance <= 32 else {
                isIgnoringCurrentManualRouteGesture = true
                return
            }
            routeBeforeManualDrag = routeCoordinates
            manualRouteDrag = ManualRouteDragState(closestRouteIndex: nearest.index)
        }

        guard let draggedCoordinate = proxy.convert(point, from: .local),
              let drag = manualRouteDrag else {
            return
        }

        routeCoordinates = ManualRouteGeometry.previewAnchors(
            currentRoute: routeBeforeManualDrag,
            draggedCoordinate: draggedCoordinate,
            transportMode: segment.transportMode,
            closestIndex: drag.closestRouteIndex
        )
        scheduleLiveManualRouteMatch(
            baseRoute: routeBeforeManualDrag,
            draggedCoordinate: draggedCoordinate,
            drag: drag
        )
    }

    private func finishManualRouteDrag(at point: CGPoint, proxy: MapProxy) {
        guard let drag = manualRouteDrag,
              let draggedCoordinate = proxy.convert(point, from: .local) else {
            if !routeBeforeManualDrag.isEmpty {
                routeCoordinates = routeBeforeManualDrag
            }
            manualRouteDrag = nil
            routeBeforeManualDrag = []
            isIgnoringCurrentManualRouteGesture = false
            liveManualRouteMatchTask?.cancel()
            liveManualRouteMatchTask = nil
            return
        }

        let baseRoute = routeBeforeManualDrag
        manualRouteDrag = nil
        routeBeforeManualDrag = []
        isIgnoringCurrentManualRouteGesture = false
        manualRouteDragRevision += 1
        liveManualRouteMatchTask?.cancel()
        liveManualRouteMatchTask = nil
        isSavingManualRoute = true

        Task { @MainActor in
            let committed = await ManualRouteGeometry.committedCoordinates(
                currentRoute: baseRoute,
                draggedCoordinate: draggedCoordinate,
                transportMode: segment.transportMode,
                closestIndex: drag.closestRouteIndex
            )

            guard committed.count > 1 else {
                isSavingManualRoute = false
                return
            }

            segment.storeManualRouteCoordinates(committed)
            routeCoordinates = committed

            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                routeCoordinates = segment.manualRouteCoordinates ?? baseRoute
                print("Failed to save manual route: \(error.localizedDescription)")
            }

            isSavingManualRoute = false
        }
    }

    private func scheduleLiveManualRouteMatch(
        baseRoute: [CLLocationCoordinate2D],
        draggedCoordinate: CLLocationCoordinate2D,
        drag: ManualRouteDragState
    ) {
        guard segment.transportMode != .boat else { return }

        manualRouteDragRevision += 1
        let revision = manualRouteDragRevision
        let transportMode = segment.transportMode

        liveManualRouteMatchTask?.cancel()
        liveManualRouteMatchTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }

            let matched = await ManualRouteGeometry.committedCoordinates(
                currentRoute: baseRoute,
                draggedCoordinate: draggedCoordinate,
                transportMode: transportMode,
                closestIndex: drag.closestRouteIndex
            )

            guard !Task.isCancelled,
                  revision == manualRouteDragRevision,
                  manualRouteDrag != nil,
                  matched.count > 1 else {
                return
            }

            routeCoordinates = matched
        }
    }

    private func nearestRoutePoint(to point: CGPoint, proxy: MapProxy) -> (index: Int, distance: CGFloat)? {
        var nearest: (index: Int, distance: CGFloat)?

        for (index, coordinate) in routeCoordinates.enumerated() {
            guard let routePoint = proxy.convert(coordinate, to: .local) else { continue }
            let distance = hypot(routePoint.x - point.x, routePoint.y - point.y)
            if nearest == nil || distance < nearest!.distance {
                nearest = (index, distance)
            }
        }

        return nearest
    }

    private func revertManualRoute() {
        guard segment.hasManualRouteCoordinates else { return }
        isSavingManualRoute = true
        segment.clearManualRouteCoordinates()

        do {
            try modelContext.save()
            Task { @MainActor in
                await refreshRouteCoordinates()
                isSavingManualRoute = false
            }
        } catch {
            modelContext.rollback()
            routeCoordinates = segment.manualRouteCoordinates ?? routeCoordinates
            isSavingManualRoute = false
            print("Failed to revert manual route: \(error.localizedDescription)")
        }
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

private struct ManualRouteDragState {
    let closestRouteIndex: Int
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
    let manualRouteCoordinatesData: Data?
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
        manualRouteCoordinatesData = segment.manualRouteCoordinatesData
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
        restored.manualRouteCoordinatesData = manualRouteCoordinatesData
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
