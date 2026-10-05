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
    @Query private var allVisitPlaces: [VisitPlace]
    @Query(sort: \KnownLocation.name, order: .forward) private var knownLocations: [KnownLocation]
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
            if TimelineDeletion.canMergeAdjacentRoutes(for: place) {
                Button("Delete and Merge Routes", role: .destructive) {
                    deletePlace(mergeAdjacentRoutes: true)
                }
            }
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
        GeometryReader { proxy in
            if proxy.size.width > 1, proxy.size.height > 1 {
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
            } else {
                Color.clear
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

                Text("Saving a name also creates or updates a Regular Place for future visits.")
                    .font(.caption).foregroundStyle(.secondary)

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
            let existingLocation = knownLocations.first { $0.id == place.regularPlaceID }
            let matchingLocation = knownLocations.first {
                $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }
            let location: KnownLocation
            if let existingLocation, existingLocation.name.localizedCaseInsensitiveCompare(trimmed) != .orderedSame {
                existingLocation.name = trimmed
                existingLocation.updatedAt = .now
                location = existingLocation
                KnownLocationLabeler.reconcile(
                    location: location,
                    replacedID: location.id,
                    definitions: knownLocations,
                    to: allVisitPlaces
                )
            } else if let matchingLocation {
                location = matchingLocation
            } else {
                location = KnownLocation(
                    name: trimmed,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    radiusMeters: min(max(place.horizontalAccuracy.isFinite ? place.horizontalAccuracy * 2 : 120, 120), 500)
                )
                modelContext.insert(location)
            }
            place.regularPlaceID = location.id
            place.regularPlaceName = location.name
            if matchingLocation == nil || existingLocation != nil {
                KnownLocationLabeler.reconcile(
                    location: location,
                    replacedID: nil,
                    definitions: knownLocations,
                    to: allVisitPlaces
                )
                // The visit being edited has a manual label and is intentionally not
                // touched by automatic reconciliation, so link it explicitly.
                place.regularPlaceID = location.id
                place.regularPlaceName = location.name
            }
        }

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .movesVisitedPlaceDidChange, object: place.id)
        } catch {
            print("Failed to save place label: \(error.localizedDescription)")
        }
    }

    private func saveComment() {
        let trimmed = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        place.comment = trimmed.isEmpty ? nil : trimmed

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .movesVisitedPlaceDidChange, object: place.id)
        } catch {
            modelContext.rollback()
            draftComment = place.comment ?? ""
            print("Failed to save place remarks: \(error.localizedDescription)")
        }
    }

    private func deletePlace(mergeAdjacentRoutes: Bool = false) {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        if mergeAdjacentRoutes {
            do {
                try TimelineDeletion.delete(
                    place: place,
                    mergeAdjacentRoutes: true,
                    in: modelContext,
                    undoManager: undoController.manager
                )
                dismiss()
            } catch {
                modelContext.rollback()
                deleteErrorMessage = error.localizedDescription
                isShowingDeleteError = true
            }
            return
        }

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
    @AppStorage(TrackingRouteDisplayMode.storageKey) private var routeDisplayMode: TrackingRouteDisplayMode = .reconstructed

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
    @State private var isSelectingSplitPoint = false
    @State private var proposedSplit: TrackSplitPlan?
    @State private var isSplittingTrack = false
    @State private var splitErrorMessage = ""
    @State private var isShowingSplitError = false
    @State private var isShowingFlightMatching = false
    @State private var isShowingFlightMerge = false

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
                        isShowingFlightMerge = true
                    } label: {
                        Image(systemName: "arrow.triangle.merge")
                    }
                    .help("Merge into Flight")

#if DEBUG
                    if segment.transportMode == .plane {
                        NavigationLink {
                            ExplorationFlightTicketDebugView(segment: segment, routeCoordinates: routeCoordinates)
                        } label: {
                            Image(systemName: "ticket.fill")
                        }
                        .help("Open DEBUG flight ticket")
                    }
#endif

                    Button {
                        setManualRouteEditing(!isEditingManualRoute)
                    } label: {
                        Image(systemName: isEditingManualRoute ? "hand.draw.fill" : "hand.draw")
                    }
                    .disabled(routeCoordinates.count < 2 || isSavingManualRoute)
                    .help(isEditingManualRoute ? "Stop editing route" : "Edit route")

                    Button {
                        setSplitPointSelection(!isSelectingSplitPoint)
                    } label: {
                        Image(systemName: isSelectingSplitPoint ? "scissors.circle.fill" : "scissors")
                    }
                    .disabled(routeCoordinates.count < 2 || isSavingManualRoute || isSplittingTrack)
                    .help(isSelectingSplitPoint ? "Cancel track split" : "Split track")

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
        .confirmationDialog(
            "Split Track Here?",
            isPresented: Binding(
                get: { proposedSplit != nil },
                set: { if !$0 { proposedSplit = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Split Track") {
                guard let plan = proposedSplit else { return }
                proposedSplit = nil
                splitTrack(using: plan)
            }
            Button("Choose Another Point") {
                proposedSplit = nil
            }
            Button("Cancel", role: .cancel) {
                proposedSplit = nil
                isSelectingSplitPoint = false
            }
        } message: {
            if let proposedSplit {
                Text("The two activities will meet at \(proposedSplit.timestamp.formatted(date: .omitted, time: .shortened)). The time is interpolated from the surrounding recorded points.")
            }
        }
        .alert("Could Not Split Track", isPresented: $isShowingSplitError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(splitErrorMessage)
        }
        .sheet(isPresented: $isShowingDetails) {
            MoveDetailsView(segment: segment, displayedRouteCoordinates: routeCoordinates)
        }
        .sheet(isPresented: $isShowingFlightMatching) {
            FlightMatchingView(segment: segment, routeCoordinates: routeCoordinates)
        }
        .sheet(isPresented: $isShowingFlightMerge) {
            FlightMergeView(anchor: segment)
        }
        .task(id: "\(routeRefreshKey)|\(routeDisplayMode.rawValue)") {
            guard RawLocationFixPresentation.schedulesRouteMatching(in: routeDisplayMode) else { return }
            await refreshRouteCoordinates()
        }
    }

    private var moveMap: some View {
        GeometryReader { container in
            if container.size.width > 1, container.size.height > 1 {
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

                        if routeDisplayMode == .rawOSLocationFixes {
                            ForEach(osLocationFixes, id: \.dedupeKey) { sample in
                                Annotation(
                                    "\(sample.source.displayName), \(sample.timestamp.formatted(date: .abbreviated, time: .standard)), ±\(Int(max(sample.horizontalAccuracy, 0).rounded())) m",
                                    coordinate: sample.coordinate,
                                    anchor: .center
                                ) {
                                    Circle()
                                        .fill(sample.source == .routeTracking || sample.source == .watchRouteTracking
                                              ? MovesPalette.routeTracking
                                              : MovesPalette.start)
                                        .frame(width: 9, height: 9)
                                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                        .accessibilityLabel("Location fix: \(sample.source.displayName), \(sample.timestamp.formatted(date: .abbreviated, time: .standard)), accuracy \(Int(max(sample.horizontalAccuracy, 0).rounded())) meters")
                                }
                            }
                        } else {
                        if activeRenderedRoute.shadowCoordinates.count > 1 {
                            MapPolyline(coordinates: activeRenderedRoute.shadowCoordinates)
                                .stroke(activeRenderedRoute.shadowTint, lineWidth: activeRenderedRoute.shadowLineWidth)
                        }

                        ForEach(Array(activeRenderedRoute.coordinateSegments.enumerated()), id: \.offset) { _, coordinates in
                            MapPolyline(coordinates: coordinates)
                                .stroke(activeRenderedRoute.tint, lineWidth: activeRenderedRoute.lineWidth)
                        }

                        ForEach(Array(activeRenderedRoute.inferredCoordinateSegments.enumerated()), id: \.offset) { _, coordinates in
                            MapPolyline(coordinates: coordinates)
                                .stroke(
                                    activeRenderedRoute.shadowTint,
                                    style: StrokeStyle(lineWidth: activeRenderedRoute.shadowLineWidth, dash: [8, 6])
                                )
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
                            ForEach(observedRouteAnchors, id: \.dedupeKey) { sample in
                                Annotation("Recorded GPS anchor", coordinate: sample.coordinate, anchor: .center) {
                                    Circle()
                                        .fill(MovesPalette.routeTracking)
                                        .frame(width: 9, height: 9)
                                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                        .accessibilityLabel("Recorded GPS anchor")
                                }
                            }
                            ForEach(Array(manualRouteWaypointCoordinates.enumerated()), id: \.offset) { index, coordinate in
                                Annotation("Waypoint", coordinate: coordinate, anchor: .center) {
                                    ManualRouteWaypointMarker(isActive: index == activeManualRouteWaypointIndex)
                                }
                            }
                        }
                        }

                        if let proposedSplit {
                            Annotation("Split point", coordinate: proposedSplit.coordinate, anchor: .center) {
                                SplitRoutePointMarker()
                            }
                        }
                    }
                    .simultaneousGesture(manualRouteEditGesture(proxy: proxy))
                    .simultaneousGesture(splitPointSelectionGesture(proxy: proxy))
                }
            } else {
                Color.clear
            }
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
                if segment.transportMode == .plane {
                    if let metadata = segment.flightMetadata,
                       metadata.provenance != .providerSuggested,
                       !metadata.isStale {
                        Label(metadata.displayName.isEmpty ? "Flight details confirmed" : metadata.displayName, systemImage: "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            isShowingFlightMatching = true
                        } label: {
                            Label("Find flight details…", systemImage: "airplane.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Optionally searches historical flight data using this move's endpoints and timing")
                    }
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
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Drag the route line to adjust it", systemImage: "hand.draw")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(activeRenderedRoute.tint)
                        if !observedRouteAnchors.isEmpty {
                            Label("Blue dots are recorded GPS points; they cannot be moved.", systemImage: "circle.fill")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(MovesPalette.routeTracking)
                        }
                    }
                }
                if isSelectingSplitPoint {
                    Label("Tap the track where the second activity should begin", systemImage: "scissors")
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

    private var observedRouteAnchors: [LocationSample] {
        segment.samples
            .filter { $0.source.isRouteTrack }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.dedupeKey < rhs.dedupeKey
            }
    }

    private var osLocationFixes: [LocationSample] {
        RawLocationFixPresentation.orderedOSFixes(from: segment.samples)
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

    private func splitPointSelectionGesture(proxy: MapProxy) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                selectSplitPoint(at: value.location, proxy: proxy)
            }
    }

    private func setSplitPointSelection(_ isSelecting: Bool) {
        isSelectingSplitPoint = isSelecting
        proposedSplit = nil
        if isSelecting {
            setManualRouteEditing(false)
        }
    }

    private func selectSplitPoint(at point: CGPoint, proxy: MapProxy) {
        guard isSelectingSplitPoint,
              let nearest = nearestRouteSegment(to: point, proxy: proxy),
              nearest.distance <= 44 else {
            return
        }

        let references = segment.samples.preferredRouteDisplaySamples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { TrackSplitReferencePoint(coordinate: $0.coordinate, timestamp: $0.timestamp) }
        guard let plan = TrackSplitPlanner.makePlan(
            routeCoordinates: routeCoordinates,
            splitSegmentIndex: nearest.segmentIndex,
            segmentFraction: nearest.fraction,
            referencePoints: references,
            startDate: segment.timelineStartDate,
            endDate: segment.endDate
        ) else {
            splitErrorMessage = "Choose a point farther from the beginning or end of the track."
            isShowingSplitError = true
            return
        }

        proposedSplit = plan
    }

    private func nearestRouteSegment(
        to point: CGPoint,
        proxy: MapProxy
    ) -> (segmentIndex: Int, fraction: Double, distance: CGFloat)? {
        guard routeCoordinates.count > 1 else { return nil }
        var nearest: (segmentIndex: Int, fraction: Double, distance: CGFloat)?

        for index in 0..<(routeCoordinates.count - 1) {
            guard let start = proxy.convert(routeCoordinates[index], to: .local),
                  let end = proxy.convert(routeCoordinates[index + 1], to: .local) else {
                continue
            }
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let lengthSquared = deltaX * deltaX + deltaY * deltaY
            guard lengthSquared > 0 else { continue }
            let fraction = min(
                max(((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / lengthSquared, 0),
                1
            )
            let projected = CGPoint(
                x: start.x + deltaX * fraction,
                y: start.y + deltaY * fraction
            )
            let distance = hypot(projected.x - point.x, projected.y - point.y)
            if nearest == nil || distance < nearest!.distance {
                nearest = (index, Double(fraction), distance)
            }
        }

        return nearest
    }

    private func splitTrack(using plan: TrackSplitPlan) {
        guard !isSplittingTrack,
              let dayTimeline = segment.dayTimeline,
              plan.timestamp > segment.timelineStartDate,
              plan.timestamp < segment.endDate else {
            return
        }

        isSplittingTrack = true
        let undoPayload = SplitMoveUndoPayload(
            segment: segment,
            displayedRouteCoordinates: routeCoordinates
        )
        let originalEndDate = segment.endDate
        let originalEndPlace = segment.endPlace
        let originalStepCount = segment.stepCount
        let originalDuration = max(originalEndDate.timeIntervalSince(segment.timelineStartDate), 1)
        let leadingDuration = max(plan.timestamp.timeIntervalSince(segment.timelineStartDate), 0)
        let leadingStepCount = originalStepCount.map {
            min(max(Int((Double($0) * leadingDuration / originalDuration).rounded()), 0), $0)
        }
        let trailingStepCount = originalStepCount.map { $0 - (leadingStepCount ?? 0) }
        let splitToken = "\(Int(plan.timestamp.timeIntervalSince1970.rounded()))-\(UUID().uuidString)"

        let splitPlace = VisitPlace(
            arrivalDate: plan.timestamp,
            departureDate: plan.timestamp,
            latitude: plan.coordinate.latitude,
            longitude: plan.coordinate.longitude,
            horizontalAccuracy: 0
        )
        splitPlace.deviceIdentifier = segment.deviceIdentifier
        splitPlace.dayTimeline = dayTimeline

        let trailingMove = MoveSegment(
            dedupeKey: "\(segment.dedupeKey)|split-after|\(splitToken)",
            startDate: plan.timestamp,
            endDate: originalEndDate,
            transportMode: segment.transportMode,
            distanceMeters: routeDistance(for: plan.trailingCoordinates),
            stepCount: trailingStepCount,
            comment: segment.comment
        )
        trailingMove.deviceIdentifier = segment.deviceIdentifier
        trailingMove.isExcludedFromConnectionStatistics = segment.isExcludedFromConnectionStatistics
        trailingMove.startPlace = splitPlace
        trailingMove.endPlace = originalEndPlace
        trailingMove.dayTimeline = dayTimeline
        trailingMove.storeManualRouteCoordinates(plan.trailingCoordinates)

        segment.dedupeKey = "\(segment.dedupeKey)|split-before|\(splitToken)"
        segment.endDate = plan.timestamp
        segment.endPlace = splitPlace
        segment.distanceMeters = routeDistance(for: plan.leadingCoordinates)
        segment.stepCount = leadingStepCount
        segment.clearCachedRouteCoordinates()
        segment.storeManualRouteCoordinates(plan.leadingCoordinates)

        for sample in undoPayload.samples {
            sample.moveSegment = sample.timestamp <= plan.timestamp ? segment : trailingMove
        }

        modelContext.insert(splitPlace)
        modelContext.insert(trailingMove)

        do {
            try modelContext.save()
            let trailingMoveID = trailingMove.id
            let splitPlaceID = splitPlace.id
            undoController.manager.registerUndo(withTarget: modelContext) { context in
                undoPayload.restore(
                    in: context,
                    trailingMoveID: trailingMoveID,
                    splitPlaceID: splitPlaceID
                )
            }
            undoController.manager.setActionName("Split Track")
            routeCoordinates = plan.leadingCoordinates
            refreshMoveGPXShareFile()
            isSelectingSplitPoint = false
            isSplittingTrack = false
            dismiss()
        } catch {
            modelContext.rollback()
            routeCoordinates = undoPayload.displayedRouteCoordinates
            refreshMoveGPXShareFile()
            splitErrorMessage = error.localizedDescription
            isShowingSplitError = true
            isSplittingTrack = false
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
        let previousManualRouteCoordinatesData = segment.manualRouteCoordinatesData
        segment.setTransportMode(newMode, provenance: .manual)
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
            if let dayKey = segment.dayTimeline?.dayKey {
                ExplorationIncrementalHooks.enqueueLiveDay(dayKey)
            }
            NotificationCenter.default.post(
                name: .movesMoveDataDidChange,
                object: segment.id
            )
            markMapAggregateDirty(for: segment)
            Task { @MainActor in
                await refreshRouteCoordinates()
            }
        } catch {
            segment.setTransportMode(previousMode, provenance: .manual)
            segment.manualRouteCoordinatesData = previousManualRouteCoordinatesData
            routeCoordinates = segment.manualRouteCoordinates ?? MoveRouteGeometry.rawCoordinates(for: segment)
            refreshMoveGPXShareFile()
            print("Failed to save move transport mode: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func refreshRouteCoordinates() async {
        guard RawLocationFixPresentation.schedulesRouteMatching(in: routeDisplayMode) else { return }
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
                NotificationCenter.default.post(
                    name: .movesMoveDataDidChange,
                    object: segment.id
                )
                markMapAggregateDirty(for: segment)
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
            markMapAggregateDirty(for: segment)
            if let dayKey = segment.dayTimeline?.dayKey {
                ExplorationIncrementalHooks.enqueueLiveDay(dayKey)
            }
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

    private func markMapAggregateDirty(for segment: MoveSegment) {
        #if os(iOS)
        ShareMapAggregateDirtyPeriods.mark(
            ShareMapAggregateStore.periodKeys(for: [segment.startDate, segment.endDate])
        )
        #endif
    }

    private func deleteMove() {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        let undoPayload = DeletedMoveUndoPayload(segment: segment)
        let affectedDayKey = segment.dayTimeline?.dayKey
        let undoManager = undoController.manager

        modelContext.delete(segment)
        do {
            try modelContext.save()
            if let affectedDayKey {
                ExplorationIncrementalHooks.enqueueLiveDay(affectedDayKey)
            }
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

struct FlightMergeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let anchor: MoveSegment
    @State private var candidates: [MoveSegment] = []
    @State private var selectedIDs: Set<UUID>
    @State private var errorMessage: String?
    @State private var plan: FlightMergePlan?
    @State private var isMerging = false

    init(anchor: MoveSegment) {
        self.anchor = anchor
        _selectedIDs = State(initialValue: [anchor.id])
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select fragments from the nearby absolute time window. The merge keeps one canonical flight and preserves recorded samples.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Nearby moves") {
                    ForEach(candidates) { move in
                        Button {
                            toggle(move.id)
                    } label: {
                            let isSelected = selectedIDs.contains(move.id)
                            let selectionImage = isSelected ? "checkmark.circle.fill" : "circle"
                            HStack(spacing: 12) {
                                Image(systemName: selectionImage)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                Image(systemName: move.transportMode.symbolName)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(move.startPlace?.displayTitle ?? "Unknown") → \(move.endPlace?.displayTitle ?? "Unknown")")
                                        .lineLimit(1)
                                    Text("\(move.timelineStartDate.formatted(date: .abbreviated, time: .shortened))  •  \(DurationFormatter.extendedText(for: move.timelineDuration))  •  \(Measurement(value: max(move.distanceMeters, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let plan {
                    Section("Preview") {
                        LabeledContent("Fragments", value: "\(plan.orderedSourceMoveIDs.count)")
                        LabeledContent("Elapsed", value: DurationFormatter.extendedText(for: plan.endDate.timeIntervalSince(plan.startDate)))
                        if !plan.removableIntermediatePlaceIDs.isEmpty {
                            Text("\(plan.removableIntermediatePlaceIDs.count) transient intermediate place(s) will be removed.")
                                .font(.footnote)
                        }
                        if !plan.preservedIntermediatePlaceIDs.isEmpty {
                            Text("Meaningful intermediate places will be kept.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Merge into Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") { merge() }
                        .disabled(selectedIDs.count < 2 || isMerging)
                }
            }
            .task {
                loadCandidates()
                refreshPlan()
            }
            .onChange(of: selectedIDs) { _, _ in
                refreshPlan()
            }
            .alert("Could Not Merge Flight", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private func loadCandidates() {
        let lower = anchor.startDate.addingTimeInterval(-36 * 60 * 60)
        let upper = anchor.endDate.addingTimeInterval(36 * 60 * 60)
        let predicate = #Predicate<MoveSegment> { move in
            move.startDate < upper && move.endDate >= lower
        }
        var descriptor = FetchDescriptor<MoveSegment>(
            predicate: predicate,
            sortBy: [SortDescriptor(\MoveSegment.startDate, order: .forward)]
        )
        descriptor.fetchLimit = 64
        candidates = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func refreshPlan() {
        guard selectedIDs.count >= 2 else {
            plan = nil
            return
        }
        plan = try? FlightMergeService(modelContext: modelContext).validate(moveIDs: Array(selectedIDs))
    }

    private func merge() {
        guard let plan else { return }
        isMerging = true
        defer { isMerging = false }
        do {
            _ = try FlightMergeService(modelContext: modelContext).merge(plan)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FlightMatchingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let segment: MoveSegment
    let routeCoordinates: [CLLocationCoordinate2D]
    let provider: any HistoricalFlightProvider

    @State private var response: FlightMatchResponse?
    @State private var errorMessage: String?
    @State private var isLoading = true

    init(
        segment: MoveSegment,
        routeCoordinates: [CLLocationCoordinate2D],
        provider: any HistoricalFlightProvider = UnavailableHistoricalFlightProvider()
    ) {
        self.segment = segment
        self.routeCoordinates = routeCoordinates
        self.provider = provider
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Finding likely flight details…")
                } else if let errorMessage {
                    ContentUnavailableView("Could Not Search", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else if let response {
                    resultContent(response)
                }
            }
            .padding()
            .navigationTitle("Flight Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await findMatches()
        }
    }

    @ViewBuilder
    private func resultContent(_ response: FlightMatchResponse) -> some View {
        if response.providerUnavailable && response.matches.isEmpty {
            ContentUnavailableView(
                "Historical Search Unavailable",
                systemImage: "network.slash",
                description: Text("No historical flight provider is configured. The recorded flight and its local keepsake remain unchanged.")
            )
        } else if response.matches.isEmpty {
            ContentUnavailableView(
                "No Matching Flight",
                systemImage: "airplane.circle",
                description: Text("No useful historical candidate matched this move. Nothing was added to the move.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(response.hasAmbiguity ? "Several flights are plausible" : "Likely flight")
                        .font(.headline)
                    Text("Candidates use airport proximity, timing, duration, route distance and provider track data where available. Confirm a candidate before it becomes move metadata.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(response.matches.prefix(5)) { match in
                        Button {
                            confirm(match)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(match.candidate.displayFlightNumber)
                                        .font(.headline)
                                    if let airlineName = match.candidate.airlineName {
                                        Text(airlineName)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(match.confidence.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption.weight(.semibold))
                                }
                                Text("\(match.candidate.origin.iataCode ?? match.candidate.origin.icaoCode) → \(match.candidate.destination.iataCode ?? match.candidate.destination.icaoCode)")
                                    .font(.subheadline.weight(.medium))
                                ForEach(match.evidence.prefix(3), id: \.signal) { evidence in
                                    Text(evidence.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("Confirm this flight")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    if segment.flightMetadata?.provenance == .providerSuggested {
                        Button("Keep recorded flight data") {
                            _ = segment.rejectProviderSuggestion()
                            try? modelContext.save()
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func findMatches() async {
        let fingerprint = FlightFingerprint(move: segment, route: routeCoordinates)
        let service = FlightMatchingService(provider: provider)
        do {
            response = try await service.match(fingerprint)
            if let bestMatch = response?.bestMatch,
               segment.storeProviderSuggestion(bestMatch) {
                try? modelContext.save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func confirm(_ match: FlightMatch) {
        guard segment.confirmFlightMatch(match) else { return }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
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
            flightMetadata: segment.flightMetadata,
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
    let flightMetadata: FlightMetadata?
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
    let photoAssetIDsRawValue: String?
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
        photoAssetIDsRawValue = place.photoAssetIDsRawValue
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

private struct SplitRoutePointMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.24), radius: 3, y: 1)

            Image(systemName: "scissors")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityLabel("Selected split point")
    }
}

private struct SplitMoveUndoPayload {
    let id: UUID
    let dedupeKey: String
    let endDate: Date
    let endPlace: VisitPlace?
    let distanceMeters: Double
    let stepCount: Int?
    let routeCacheSignature: String?
    let routeCacheCoordinatesData: Data?
    let manualRouteCoordinatesData: Data?
    let samples: [LocationSample]
    let displayedRouteCoordinates: [CLLocationCoordinate2D]

    init(
        segment: MoveSegment,
        displayedRouteCoordinates: [CLLocationCoordinate2D]
    ) {
        id = segment.id
        dedupeKey = segment.dedupeKey
        endDate = segment.endDate
        endPlace = segment.endPlace
        distanceMeters = segment.distanceMeters
        stepCount = segment.stepCount
        routeCacheSignature = segment.routeCacheSignature
        routeCacheCoordinatesData = segment.routeCacheCoordinatesData
        manualRouteCoordinatesData = segment.manualRouteCoordinatesData
        samples = segment.samples
        self.displayedRouteCoordinates = displayedRouteCoordinates
    }

    @MainActor
    func restore(
        in context: ModelContext,
        trailingMoveID: UUID,
        splitPlaceID: UUID
    ) {
        guard let original = try? context.fetch(FetchDescriptor<MoveSegment>())
            .first(where: { $0.id == id }) else {
            return
        }

        original.dedupeKey = dedupeKey
        original.endDate = endDate
        original.endPlace = endPlace
        original.distanceMeters = distanceMeters
        original.stepCount = stepCount
        original.routeCacheSignature = routeCacheSignature
        original.routeCacheCoordinatesData = routeCacheCoordinatesData
        original.manualRouteCoordinatesData = manualRouteCoordinatesData
        samples.forEach { $0.moveSegment = original }

        if let trailingMove = try? context.fetch(FetchDescriptor<MoveSegment>())
            .first(where: { $0.id == trailingMoveID }) {
            context.delete(trailingMove)
        }
        if let splitPlace = try? context.fetch(FetchDescriptor<VisitPlace>())
            .first(where: { $0.id == splitPlaceID }) {
            context.delete(splitPlace)
        }
        try? context.save()
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
    let photoAssetIDsRawValue: String?
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
        photoAssetIDsRawValue = place.photoAssetIDsRawValue
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
        restored.photoAssetIDsRawValue = photoAssetIDsRawValue
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
