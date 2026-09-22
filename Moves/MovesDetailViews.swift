//
//  MovesDetailViews.swift
//  Raul
//
//  Place and move detail screens extracted from ContentView.
//

import CoreTransferable
import Foundation
import MapKit
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PlaceMapDetailView: View {
    @EnvironmentObject private var undoController: AppUndoController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var place: VisitPlace
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false

    @State private var camera: MapCameraPosition
    @State private var draftLabel: String
    @State private var draftComment: String
    @State private var isConfirmingDeletion = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage = ""
    @State private var isShowingDeleteError = false

    init(place: VisitPlace) {
        self.place = place
        _draftLabel = State(initialValue: place.userLabel ?? place.autoLabel ?? "")
        _draftComment = State(initialValue: place.comment ?? "")
        _camera = State(initialValue: .region(
            MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            if LandscapeLayoutSettings.isLandscapePhone(proxy.size) {
                LandscapeSplitView {
                    placeMap
                } controlPane: {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                Spacer()
                                LandscapePaneSideButton()
                            }
                            placeControls
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.hidden)
                }
                .safeAreaPadding(.horizontal, 12)
                .safeAreaPadding(.bottom, 8)
            } else {
                placeMap
                    .overlay(alignment: .bottom) {
                        placeControls
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .safeAreaPadding(.bottom, 12)
                    }
            }
        }
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
    }

    private var placeMap: some View {
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
    }

    private var placeControls: some View {
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

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Remarks", text: $draftComment, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(2...5)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MovesPalette.textFieldBackground.opacity(0.92))
                        )
                        .accessibilityLabel("Place remarks")

                    Button("Save") {
                        saveComment()
                    }
                    .buttonStyle(.bordered)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panelSurface()
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

    private func saveComment() {
        let trimmed = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        place.comment = trimmed.isEmpty ? nil : trimmed

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            draftComment = place.comment ?? ""
            print("Failed to save place remarks: \(error.localizedDescription)")
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
    private static let exportFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    @EnvironmentObject private var undoController: AppUndoController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Bindable var segment: MoveSegment
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false

    @State private var camera: MapCameraPosition
    @State private var routeCoordinates: [CLLocationCoordinate2D]
    @State private var moveGPXShareFile: GPXShareFile?
    @State private var draftComment: String
    @State private var isShowingTransportPicker = false
    @State private var isEditingManualRoute = false
    @State private var manualRouteDrag: ManualRouteDragState?
    @State private var routeBeforeManualDrag: [CLLocationCoordinate2D] = []
    @State private var manualRouteWaypointCoordinates: [CLLocationCoordinate2D] = []
    @State private var activeManualRouteWaypointIndex: Int?
    @State private var liveManualRouteMatchTask: Task<Void, Never>?
    @State private var manualRouteDragRevision = 0
    @State private var isIgnoringCurrentManualRouteGesture = false
    @State private var isSavingManualRoute = false
    @State private var isConfirmingDeletion = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage = ""
    @State private var isShowingDeleteError = false
    @State private var isShowingHealthOpenError = false
    @State private var isShowingDetails = false

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
        _moveGPXShareFile = State(
            initialValue: Self.makeGPXShareFile(for: segment, coordinates: initialRoute)
        )
        _draftComment = State(initialValue: segment.comment ?? "")
    }

    var body: some View {
        GeometryReader { proxy in
            if LandscapeLayoutSettings.isLandscapePhone(proxy.size) {
                LandscapeSplitView {
                    moveMap
                } controlPane: {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                Spacer()
                                LandscapePaneSideButton()
                            }
                            moveControls
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.hidden)
                }
                .safeAreaPadding(.horizontal, 12)
                .safeAreaPadding(.bottom, 8)
            } else {
                moveMap
                    .overlay(alignment: .bottom) {
                        moveControls
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .safeAreaPadding(.bottom, 12)
                    }
            }
        }
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

                    moveShareButton

                    Button {
                        setManualRouteEditing(!isEditingManualRoute)
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
        .sheet(isPresented: $isShowingDetails) {
            MoveDetailsView(segment: segment, displayedRouteCoordinates: routeCoordinates)
        }
        .task(id: routeRefreshKey) {
            await refreshRouteCoordinates()
        }
    }

    private var moveMap: some View {
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

                ForEach(Array(activeRenderedRoute.coordinateSegments.enumerated()), id: \.offset) { _, coordinates in
                    MapPolyline(coordinates: coordinates)
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

                if isEditingManualRoute {
                    ForEach(Array(manualRouteWaypointCoordinates.enumerated()), id: \.offset) { index, coordinate in
                        Annotation("Waypoint", coordinate: coordinate, anchor: .center) {
                            ManualRouteWaypointMarker(isActive: index == activeManualRouteWaypointIndex)
                        }
                    }
                }
            }
            .simultaneousGesture(manualRouteEditGesture(proxy: proxy))
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
    }

    private var moveControls: some View {
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
                HStack(spacing: 10) {
                    Text("\(DurationFormatter.text(for: segment.timelineDuration))   \(Measurement(value: max(routeDistance(for: routeCoordinates), 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.75))

                    Spacer(minLength: 0)

                    Button {
                        isShowingDetails = true
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Shows move details and raw location data")
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Remarks", text: $draftComment, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(2...5)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MovesPalette.textFieldBackground.opacity(0.92))
                        )
                        .accessibilityLabel("Move remarks")

                    Button("Save") {
                        saveComment()
                    }
                    .buttonStyle(.bordered)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panelSurface()
    }

    @ViewBuilder
    private var moveShareButton: some View {
        if let exportFile = moveGPXShareFile {
            ShareLink(
                item: exportFile,
                subject: Text(moveRouteTitle),
                message: Text("GPX route exported from Moves."),
                preview: SharePreview(exportFile.filename)
            ) {
                Label("Share GPX", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .disabled(isSavingManualRoute || manualRouteDrag != nil)
            .help("Share move as GPX")
            .accessibilityLabel("Share move as GPX")
        } else {
            Button {} label: {
                Label("Share GPX", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .disabled(true)
            .help("A route is needed to share this move as GPX")
            .accessibilityLabel("Share move as GPX")
        }
    }

    private static func makeGPXShareFile(
        for segment: MoveSegment,
        coordinates: [CLLocationCoordinate2D]
    ) -> GPXShareFile? {
        let timestamp = Self.exportFilenameDateFormatter.string(from: segment.timelineStartDate)
        guard let payload = TimelineExporter.makeMoveGPXPayload(
            move: segment,
            coordinates: coordinates,
            fileStem: "moves-\(timestamp)-\(segment.transportMode.rawValue)"
        ) else {
            return nil
        }

        return GPXShareFile(data: payload.data, filename: payload.filename)
    }

    private func refreshMoveGPXShareFile() {
        moveGPXShareFile = Self.makeGPXShareFile(for: segment, coordinates: routeCoordinates)
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

    private func saveComment() {
        let trimmed = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        segment.comment = trimmed.isEmpty ? nil : trimmed

        do {
            try modelContext.save()
            refreshMoveGPXShareFile()
        } catch {
            modelContext.rollback()
            draftComment = segment.comment ?? ""
            print("Failed to save move remarks: \(error.localizedDescription)")
        }
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

    private func setManualRouteEditing(_ isEditing: Bool) {
        isEditingManualRoute = isEditing
        manualRouteDrag = nil
        isIgnoringCurrentManualRouteGesture = false
        activeManualRouteWaypointIndex = nil
        liveManualRouteMatchTask?.cancel()
        liveManualRouteMatchTask = nil

        manualRouteWaypointCoordinates = isEditing
            ? ManualRouteGeometry.waypoints(for: routeCoordinates, transportMode: segment.transportMode)
            : []
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
        segment.distanceMeters = routeDistance(for: routeCoordinates)
        refreshMoveGPXShareFile()
        manualRouteWaypointCoordinates = isEditingManualRoute
            ? ManualRouteGeometry.waypoints(for: routeCoordinates, transportMode: newMode)
            : []

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
            routeCoordinates = segment.manualRouteCoordinates ?? MoveRouteGeometry.rawCoordinates(for: segment)
            refreshMoveGPXShareFile()
            print("Failed to save move transport mode: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func refreshRouteCoordinates() async {
        routeCoordinates = await RoadRouteMatcher.matchedCoordinates(for: segment)
        refreshMoveGPXShareFile()
        if isEditingManualRoute, manualRouteDrag == nil {
            manualRouteWaypointCoordinates = ManualRouteGeometry.waypoints(
                for: routeCoordinates,
                transportMode: segment.transportMode
            )
        }
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

        let anchors = ManualRouteGeometry.editAnchors(
            currentRoute: routeBeforeManualDrag,
            draggedCoordinate: draggedCoordinate,
            transportMode: segment.transportMode,
            closestIndex: drag.closestRouteIndex
        )
        manualRouteWaypointCoordinates = anchors
        activeManualRouteWaypointIndex = nearestCoordinateIndex(to: draggedCoordinate, in: anchors)
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
            activeManualRouteWaypointIndex = nil
            isIgnoringCurrentManualRouteGesture = false
            liveManualRouteMatchTask?.cancel()
            liveManualRouteMatchTask = nil
            return
        }

        let baseRoute = routeBeforeManualDrag
        manualRouteDrag = nil
        routeBeforeManualDrag = []
        activeManualRouteWaypointIndex = nil
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
            segment.distanceMeters = routeDistance(for: committed)
            refreshMoveGPXShareFile()
            if isEditingManualRoute {
                manualRouteWaypointCoordinates = ManualRouteGeometry.waypoints(
                    for: committed,
                    transportMode: segment.transportMode
                )
            }

            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                routeCoordinates = segment.manualRouteCoordinates ?? baseRoute
                refreshMoveGPXShareFile()
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

    private func nearestCoordinateIndex(
        to coordinate: CLLocationCoordinate2D,
        in coordinates: [CLLocationCoordinate2D]
    ) -> Int? {
        coordinates.enumerated().min { lhs, rhs in
            RouteCoordinateOps.distanceMeters(from: lhs.element, to: coordinate)
                < RouteCoordinateOps.distanceMeters(from: rhs.element, to: coordinate)
        }?.offset
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
                if isEditingManualRoute {
                    manualRouteWaypointCoordinates = ManualRouteGeometry.waypoints(
                        for: routeCoordinates,
                        transportMode: segment.transportMode
                    )
                }
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

private struct MoveDetailsView: View {
    @Environment(\.dismiss) private var dismiss

    let segment: MoveSegment
    let displayedRouteCoordinates: [CLLocationCoordinate2D]

    @State private var copiedRawData = false
    @State private var isShowingRawData = false

    private var sortedSamples: [LocationSample] {
        segment.samples.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.dedupeKey < rhs.dedupeKey
        }
    }

    private var sourceSummary: [(name: String, count: Int)] {
        Dictionary(grouping: sortedSamples, by: \.sourceRawValue)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var renderedDistance: CLLocationDistance {
        routeDistance(for: displayedRouteCoordinates)
    }

    private var averageSpeed: String? {
        guard DurationFormatter.showsNonzeroMinutes(for: segment.timelineDuration) else {
            return nil
        }
        let kilometersPerHour = (segment.distanceMeters / segment.timelineDuration) * 3.6
        guard kilometersPerHour.isFinite else { return nil }
        return MovesMeasurementFormatter.speed(kilometersPerHour: kilometersPerHour)
    }

    private var rawData: String {
        let payload = RawMoveData(
            id: segment.id.uuidString,
            deviceIdentifier: segment.deviceIdentifier,
            dedupeKey: segment.dedupeKey,
            startDate: segment.startDate,
            timelineStartDate: segment.timelineStartDate,
            endDate: segment.endDate,
            transportMode: segment.transportModeRawValue,
            distanceMeters: segment.distanceMeters,
            stepCount: segment.stepCount,
            comment: segment.comment,
            isExcludedFromConnectionStatistics: segment.isExcludedFromConnectionStatistics,
            createdAt: segment.createdAt,
            dayKey: segment.dayTimeline?.dayKey,
            startPlace: RawPlaceData(place: segment.startPlace),
            endPlace: RawPlaceData(place: segment.endPlace),
            routeCacheSignature: segment.routeCacheSignature,
            routeCacheByteCount: segment.routeCacheCoordinatesData?.count,
            manualRouteByteCount: segment.manualRouteCoordinatesData?.count,
            displayedRouteCoordinateCount: displayedRouteCoordinates.count,
            samples: sortedSamples.map(RawLocationSampleData.init)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return "Raw data could not be encoded."
        }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    SettingsCard(title: "Move") {
                        Text("\(segment.startPlace?.displayTitle ?? "Unknown start") → \(segment.endPlace?.displayTitle ?? "Unknown destination")")
                            .font(.system(size: 18, weight: .bold, design: .rounded))

                        MoveDetailRow("Mode", segment.transportMode.title)
                        MoveDetailRow("Started", segment.timelineStartDate.formatted(date: .complete, time: .complete))
                        MoveDetailRow("Finished", segment.endDate.formatted(date: .complete, time: .complete))
                        MoveDetailRow("Duration", DurationFormatter.text(for: segment.timelineDuration))
                        MoveDetailRow("Recorded distance", Measurement(value: max(segment.distanceMeters, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                        MoveDetailRow("Displayed route", Measurement(value: max(renderedDistance, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                        if let averageSpeed {
                            MoveDetailRow("Average speed", averageSpeed)
                        }
                    }

                    SettingsCard(title: "Capture") {
                        MoveDetailRow("Recorded samples", sortedSamples.count.formatted())
                        MoveDetailRow("Route coordinates", displayedRouteCoordinates.count.formatted())
                        MoveDetailRow("Source", segment.usesHealthWorkoutRoute ? "Apple Health workout route" : segment.usesHighAccuracyRouteTracking ? "Route tracking" : "Location history")

                        if !sourceSummary.isEmpty {
                            Divider()
                            ForEach(sourceSummary, id: \.name) { source in
                                MoveDetailRow(source.name, source.count.formatted())
                            }
                        }
                    }

                    SettingsCard(title: "Endpoints") {
                        MoveEndpointDetail(title: "Start", place: segment.startPlace)
                        Divider()
                        MoveEndpointDetail(title: "End", place: segment.endPlace)
                    }

                    SettingsCard(title: "Raw Data") {
                        Text("The JSON below includes the persisted move, its endpoints, and every recorded location sample.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        Button {
                            UIPasteboard.general.string = rawData
                            copiedRawData = true
                        } label: {
                            Label(copiedRawData ? "Copied Raw Data" : "Copy Raw Data", systemImage: copiedRawData ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        DisclosureGroup("Show Raw JSON", isExpanded: $isShowingRawData) {
                            ScrollView([.horizontal, .vertical]) {
                                Text(rawData)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(height: 360)
                            .background(MovesPalette.textFieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .navigationTitle("Move Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct MoveDetailRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
    }
}

private struct MoveEndpointDetail: View {
    let title: String
    let place: VisitPlace?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
            if let place {
                Text(place.displayTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("\(place.latitude.formatted(.number.precision(.fractionLength(6)))), \(place.longitude.formatted(.number.precision(.fractionLength(6))))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Accuracy ±\(MovesMeasurementFormatter.accuracy(meters: place.horizontalAccuracy))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No saved place")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RawMoveData: Encodable {
    let id: String
    let deviceIdentifier: String
    let dedupeKey: String
    let startDate: Date
    let timelineStartDate: Date
    let endDate: Date
    let transportMode: String
    let distanceMeters: Double
    let stepCount: Int?
    let comment: String?
    let isExcludedFromConnectionStatistics: Bool
    let createdAt: Date
    let dayKey: String?
    let startPlace: RawPlaceData?
    let endPlace: RawPlaceData?
    let routeCacheSignature: String?
    let routeCacheByteCount: Int?
    let manualRouteByteCount: Int?
    let displayedRouteCoordinateCount: Int
    let samples: [RawLocationSampleData]
}

private struct RawPlaceData: Encodable {
    let id: String
    let arrivalDate: Date
    let departureDate: Date?
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let userLabel: String?
    let autoLabel: String?
    let comment: String?
    let createdAt: Date

    init?(place: VisitPlace?) {
        guard let place else { return nil }
        id = place.id.uuidString
        arrivalDate = place.arrivalDate
        departureDate = place.departureDate
        latitude = place.latitude
        longitude = place.longitude
        horizontalAccuracy = place.horizontalAccuracy
        userLabel = place.userLabel
        autoLabel = place.autoLabel
        comment = place.comment
        createdAt = place.createdAt
    }
}

private struct RawLocationSampleData: Encodable {
    let dedupeKey: String
    let deviceIdentifier: String
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let speed: Double
    let source: String
    let createdAt: Date

    init(_ sample: LocationSample) {
        dedupeKey = sample.dedupeKey
        deviceIdentifier = sample.deviceIdentifier
        timestamp = sample.timestamp
        latitude = sample.latitude
        longitude = sample.longitude
        altitude = sample.altitude
        horizontalAccuracy = sample.horizontalAccuracy
        speed = sample.speed
        source = sample.sourceRawValue
        createdAt = sample.createdAt
    }
}

private struct ManualRouteDragState {
    let closestRouteIndex: Int
}

private struct ManualRouteWaypointMarker: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? Color.accentColor : Color(uiColor: .systemBackground))
            .frame(width: isActive ? 14 : 10, height: isActive ? 14 : 10)
            .overlay {
                Circle()
                    .stroke(Color.accentColor, lineWidth: isActive ? 3 : 2)
            }
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
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
    let comment: String?
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
        comment = place.comment
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
            autoLabel: autoLabel,
            comment: comment
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
    let comment: String?
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
        comment = segment.comment
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
            stepCount: stepCount,
            comment: comment
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
