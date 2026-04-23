//
//  MovesSettingsView.swift
//  Raul
//
//  Settings screen extracted from ContentView.
//

import Foundation
import Combine
import CoreLocation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MovesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false

    let dayTimelines: [DayTimeline]
    let selectedDayKey: String
    let captureManager: MovesLocationCaptureManager

    @State private var isExporting = false
    @State private var exportDocument: TimelineExportDocument?
    @State private var exportContentType: UTType = .xml
    @State private var exportFilename = "moves-export"
    @State private var exportMessage = ""
    @State private var isShowingExportMessage = false
    @State private var hasDedupeUndoSnapshot = false
    @State private var isConfirmingHistoricalDeduplication = false
    @State private var isRunningHistoricalDeduplication = false
    @State private var isUndoingHistoricalDeduplication = false
    @State private var maintenanceMessage = ""
    @State private var isShowingMaintenanceMessage = false

    init(
        dayTimelines: [DayTimeline],
        selectedDayKey: String,
        captureManager: MovesLocationCaptureManager
    ) {
        self.dayTimelines = dayTimelines
        self.selectedDayKey = selectedDayKey
        self.captureManager = captureManager
    }

    private var selectedDay: DayTimeline? {
        dayTimelines.first(where: { $0.dayKey == selectedDayKey })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    RouteTrackingSettingsSection(captureManager: captureManager)

                    SettingsCard(title: "Map Appearance") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show big map markers", isOn: $showsBigMarkers)

                            Text("When this is off, maps use small dots so more of the map stays visible.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsCard(title: "GPX Export") {
                        SettingsActionRow(
                            title: "Selected Day (.gpx)",
                            systemImage: "calendar",
                            isDisabled: dayTimelines.isEmpty
                        ) {
                            export(.gpx, scope: .selectedDay)
                        }

                        SettingsActionRow(
                            title: "All Days (.gpx)",
                            systemImage: "calendar.badge.clock",
                            isDisabled: dayTimelines.isEmpty
                        ) {
                            export(.gpx, scope: .allDays)
                        }
                    }

                    SettingsCard(title: "Other Formats") {
                        SettingsActionRow(
                            title: "Selected Day (.geojson)",
                            systemImage: "map",
                            isDisabled: dayTimelines.isEmpty
                        ) {
                            export(.geoJSON, scope: .selectedDay)
                        }

                        SettingsActionRow(
                            title: "All Days (.geojson)",
                            systemImage: "map.fill",
                            isDisabled: dayTimelines.isEmpty
                        ) {
                            export(.geoJSON, scope: .allDays)
                        }

                        SettingsActionRow(
                            title: "All Days Places+Moves (.csv)",
                            systemImage: "tablecells",
                            isDisabled: dayTimelines.isEmpty
                        ) {
                            export(.csv, scope: .allDays)
                        }
                    }

                    SettingsCard(title: "Data Maintenance") {
                        SettingsActionRow(
                            title: isRunningHistoricalDeduplication
                                ? "Deduplicating existing data..."
                                : "Deduplicate existing data",
                            systemImage: "wand.and.stars",
                            isDisabled: isRunningHistoricalDeduplication || isUndoingHistoricalDeduplication
                        ) {
                            isConfirmingHistoricalDeduplication = true
                        }

                        SettingsActionRow(
                            title: isUndoingHistoricalDeduplication
                                ? "Restoring previous data..."
                                : "Undo last deduplication",
                            systemImage: "arrow.uturn.backward.circle",
                            isDisabled: !hasDedupeUndoSnapshot
                                || isRunningHistoricalDeduplication
                                || isUndoingHistoricalDeduplication
                        ) {
                            undoHistoricalDeduplication()
                        }

                        Text("Before deduplication, Moves creates a local snapshot so you can restore the previous state with one tap.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    CreatedByView()
                        .panelSurface()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 18)
            }
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }

        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success(let url):
                exportMessage = "Exported to \(url.lastPathComponent)"
            case .failure(let error):
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
            isShowingExportMessage = true
        }
        .onAppear {
            hasDedupeUndoSnapshot = TimelineDeduplicationSnapshotStore.hasSnapshot
        }
        .confirmationDialog(
            "Deduplicate Existing Data?",
            isPresented: $isConfirmingHistoricalDeduplication,
            titleVisibility: .visible
        ) {
            Button("Deduplicate", role: .destructive) {
                runHistoricalDeduplication()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moves will merge old duplicate places and moves. For duplicate stays at the same location/time, it keeps the one that best fits surrounding moves (or the longer stay if there is no move context). A snapshot is saved first so you can undo.")
        }
        .alert("Export", isPresented: $isShowingExportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportMessage)
        }
        .alert("Data Maintenance", isPresented: $isShowingMaintenanceMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(maintenanceMessage)
        }
    }

    private func export(_ format: TimelineExportFormat, scope: TimelineExportScope) {
        let days: [DayTimeline]
        let scopeName: String

        switch scope {
        case .allDays:
            days = dayTimelines
            scopeName = "all-days"

        case .selectedDay:
            guard let selectedDay else {
                exportMessage = "No day selected for export."
                isShowingExportMessage = true
                return
            }
            days = [selectedDay]
            scopeName = selectedDay.dayKey
        }

        guard !days.isEmpty else {
            exportMessage = "No timeline data available yet."
            isShowingExportMessage = true
            return
        }

        guard let payload = TimelineExporter.makePayload(
            days: days,
            format: format,
            fileStem: "moves-\(scopeName)"
        ) else {
            exportMessage = "Could not build export file."
            isShowingExportMessage = true
            return
        }

        exportDocument = TimelineExportDocument(data: payload.data)
        exportContentType = payload.contentType
        exportFilename = payload.filename
        isExporting = true
    }

    @MainActor
    private func runHistoricalDeduplication() {
        guard !isRunningHistoricalDeduplication, !isUndoingHistoricalDeduplication else { return }

        isRunningHistoricalDeduplication = true

        Task { @MainActor in
            defer { isRunningHistoricalDeduplication = false }

            do {
                let repository = SwiftDataTimelineRepository(modelContext: modelContext)
                let snapshot = try repository.createUndoSnapshot()
                try TimelineDeduplicationSnapshotStore.save(snapshot)

                let report = try repository.runHistoricalDeduplication()
                hasDedupeUndoSnapshot = TimelineDeduplicationSnapshotStore.hasSnapshot

                if report.totalRemovedCount == 0 {
                    maintenanceMessage = "No duplicates were found in existing data. A restore snapshot is still available."
                } else {
                    maintenanceMessage = "Deduplication removed \(report.removedPlaceCount) place duplicate(s) and \(report.removedMoveCount) move duplicate(s). Duplicate stays now keep the best-fitting entry (or the longer one without move context). You can undo this run from Settings."
                }
            } catch {
                maintenanceMessage = "Deduplication failed: \(error.localizedDescription)"
            }

            isShowingMaintenanceMessage = true
        }
    }

    @MainActor
    private func undoHistoricalDeduplication() {
        guard hasDedupeUndoSnapshot, !isUndoingHistoricalDeduplication, !isRunningHistoricalDeduplication else {
            return
        }

        isUndoingHistoricalDeduplication = true

        Task { @MainActor in
            defer { isUndoingHistoricalDeduplication = false }

            do {
                let snapshot = try TimelineDeduplicationSnapshotStore.load()
                let repository = SwiftDataTimelineRepository(modelContext: modelContext)
                try repository.restoreFromUndoSnapshot(snapshot)
                try TimelineDeduplicationSnapshotStore.clear()
                hasDedupeUndoSnapshot = TimelineDeduplicationSnapshotStore.hasSnapshot
                maintenanceMessage = "Restored the previous timeline snapshot from before deduplication."
            } catch {
                maintenanceMessage = "Could not restore snapshot: \(error.localizedDescription)"
            }

            isShowingMaintenanceMessage = true
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

private struct SettingsActionRow: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .padding(.vertical, 5)
    }
}

@MainActor
private func routeTrackingBannerData(
    isDemoMode: Bool,
    authorizationStatus: CLAuthorizationStatus,
    lastErrorMessage: String?,
    duration: TemporaryRouteTrackingDuration,
    endsAt: Date?,
    stopsAtFiftyPercentBattery: Bool,
    stopsInLowPowerMode: Bool,
    context: TrackingStatusBannerContext
) -> TrackingStatusBannerData? {
    if isDemoMode {
        return nil
    }

    if let lastErrorMessage {
        return TrackingStatusBannerData(
            title: "Location tracking error",
            message: lastErrorMessage,
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
        )
    }

    if let endsAt, endsAt > .now {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return TrackingStatusBannerData(
                title: "Real route tracking on",
                message: routeTrackingBannerMessage(
                    duration: duration,
                    stopsAtFiftyPercentBattery: stopsAtFiftyPercentBattery,
                    stopsInLowPowerMode: stopsInLowPowerMode,
                    context: context,
                    authorizationStatus: authorizationStatus
                ),
                systemImage: "location.fill.viewfinder",
                tint: MovesPalette.routeTracking,
                buttonTitle: context == .timeline ? "Turn off now" : nil,
                buttonRole: context == .timeline ? .destructive : nil
            )
        case .notDetermined, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    guard context == .settings else {
        return nil
    }

    switch authorizationStatus {
    case .authorizedAlways:
        return TrackingStatusBannerData(
            title: "Background tracking is enabled",
            message: "Moves can record in the background.",
            systemImage: "location.fill",
            tint: MovesPalette.place
        )
    case .authorizedWhenInUse:
        return TrackingStatusBannerData(
            title: "Location access is enabled",
            message: "Moves can read location while open. Grant Always to keep recording in the background.",
            systemImage: "location.fill",
            tint: MovesPalette.start
        )
    case .notDetermined:
        return TrackingStatusBannerData(
            title: "Location access needed",
            message: "Open Moves to allow location access and start recording.",
            systemImage: "location.slash",
            tint: .secondary
        )
    case .denied:
        return TrackingStatusBannerData(
            title: "Location access denied",
            message: "Enable location in Settings if you want Moves to record visits and movement.",
            systemImage: "location.slash",
            tint: .secondary
        )
    case .restricted:
        return TrackingStatusBannerData(
            title: "Location access restricted",
            message: "This device does not allow location access for Moves.",
            systemImage: "lock.fill",
            tint: .secondary
        )
    @unknown default:
        return TrackingStatusBannerData(
            title: "Unknown location state",
            message: "Moves could not determine the current location permission state.",
            systemImage: "questionmark.circle",
            tint: .secondary
        )
    }
}

private func routeTrackingBannerMessage(
    duration: TemporaryRouteTrackingDuration,
    stopsAtFiftyPercentBattery: Bool,
    stopsInLowPowerMode: Bool,
    context: TrackingStatusBannerContext,
    authorizationStatus: CLAuthorizationStatus
) -> String {
    let durationText = duration.availabilityText
    let autoStopText = routeTrackingAutoStopText(
        stopsAtFiftyPercentBattery: stopsAtFiftyPercentBattery,
        stopsInLowPowerMode: stopsInLowPowerMode
    )

    switch authorizationStatus {
    case .authorizedAlways:
        switch context {
        case .timeline:
            return "Frequent GPS updates are enabled \(durationText). Battery use is higher.\(autoStopText)"
        case .settings:
            return "Frequent GPS updates are enabled \(durationText). Battery use is higher and Moves will switch back automatically.\(autoStopText)"
        }
    case .authorizedWhenInUse:
        switch context {
        case .timeline:
            return "Frequent GPS updates are enabled \(durationText) while Moves is open. Battery use is higher. Always is needed for background tracking.\(autoStopText)"
        case .settings:
            return "Frequent GPS updates are enabled \(durationText) while Moves is open. Battery use is higher. Always is needed for background tracking.\(autoStopText)"
        }
    case .notDetermined, .denied, .restricted:
        switch context {
        case .timeline:
            return "Frequent GPS updates are ready once location access is allowed."
        case .settings:
            return "Frequent GPS updates are ready once location access is allowed."
        }
    @unknown default:
        return "Frequent GPS updates are enabled."
    }
}

private func routeTrackingAutoStopText(
    stopsAtFiftyPercentBattery: Bool,
    stopsInLowPowerMode: Bool
) -> String {
    switch (stopsAtFiftyPercentBattery, stopsInLowPowerMode) {
    case (true, true):
        return " It will also stop if battery reaches 50% or Low Power Mode turns on."
    case (true, false):
        return " It will also stop if battery reaches 50%."
    case (false, true):
        return " It will also stop if Low Power Mode turns on."
    case (false, false):
        return ""
    }
}

private struct RouteTrackingSettingsSection: View {
    @Environment(\.openURL) private var openURL
    let captureManager: MovesLocationCaptureManager

    @State private var routeTrackingDuration: TemporaryRouteTrackingDuration
    @State private var routeTrackingEndsAt: Date?
    @State private var routeTrackingAuthorizationStatus: CLAuthorizationStatus
    @State private var routeTrackingLastErrorMessage: String?
    @State private var routeTrackingStopsAtFiftyPercentBattery: Bool
    @State private var routeTrackingStopsInLowPowerMode: Bool
    @State private var routeTrackingStopNotificationEnabled: Bool
    @State private var isShowingNotificationPermissionAlert = false

    init(captureManager: MovesLocationCaptureManager) {
        self.captureManager = captureManager
        _routeTrackingDuration = State(initialValue: captureManager.temporaryRouteTrackingDuration)
        _routeTrackingEndsAt = State(initialValue: captureManager.temporaryRouteTrackingEndsAt)
        _routeTrackingAuthorizationStatus = State(initialValue: captureManager.authorizationStatus)
        _routeTrackingLastErrorMessage = State(initialValue: captureManager.lastErrorMessage)
        _routeTrackingStopsAtFiftyPercentBattery = State(
            initialValue: captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery
        )
        _routeTrackingStopsInLowPowerMode = State(
            initialValue: captureManager.temporaryRouteTrackingStopsInLowPowerMode
        )
        _routeTrackingStopNotificationEnabled = State(
            initialValue: captureManager.temporaryRouteTrackingStopNotificationEnabled
        )
    }

    private var routeTrackingStopsAtBatteryFiftyBinding: Binding<Bool> {
        Binding(
            get: { routeTrackingStopsAtFiftyPercentBattery },
            set: { newValue in
                routeTrackingStopsAtFiftyPercentBattery = newValue
                captureManager.updateTemporaryRouteTrackingAutoStopRules(
                    stopsAtFiftyPercentBattery: newValue,
                    stopsInLowPowerMode: routeTrackingStopsInLowPowerMode
                )
            }
        )
    }

    private var routeTrackingStopsInLowPowerModeBinding: Binding<Bool> {
        Binding(
            get: { routeTrackingStopsInLowPowerMode },
            set: { newValue in
                routeTrackingStopsInLowPowerMode = newValue
                captureManager.updateTemporaryRouteTrackingAutoStopRules(
                    stopsAtFiftyPercentBattery: routeTrackingStopsAtFiftyPercentBattery,
                    stopsInLowPowerMode: newValue
                )
            }
        )
    }

    private var routeTrackingStopNotificationBinding: Binding<Bool> {
        Binding(
            get: { routeTrackingStopNotificationEnabled },
            set: { newValue in
                if newValue {
                    Task { @MainActor in
                        await enableRouteTrackingStopNotifications()
                    }
                } else {
                    routeTrackingStopNotificationEnabled = false
                    captureManager.disableTemporaryRouteTrackingStopNotifications()
                }
            }
        )
    }

    private var bannerData: TrackingStatusBannerData? {
        routeTrackingBannerData(
            isDemoMode: captureManager.isDemoMode,
            authorizationStatus: routeTrackingAuthorizationStatus,
            lastErrorMessage: routeTrackingLastErrorMessage,
            duration: routeTrackingDuration,
            endsAt: routeTrackingEndsAt,
            stopsAtFiftyPercentBattery: routeTrackingStopsAtFiftyPercentBattery,
            stopsInLowPowerMode: routeTrackingStopsInLowPowerMode,
            context: .settings
        )
    }

    @MainActor
    private func enableRouteTrackingStopNotifications() async {
        let result = await captureManager.enableTemporaryRouteTrackingStopNotifications()
        routeTrackingStopNotificationEnabled = true

        if result == .needsSettings {
            isShowingNotificationPermissionAlert = true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let bannerData {
                TrackingStatusBanner(data: bannerData)
            }

            if !captureManager.isDemoMode {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Real Route Tracking")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text("Use frequent GPS updates for the actual route when you need more detail. Battery use increases while this is on.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    if routeTrackingAuthorizationStatus == .authorizedAlways ||
                        routeTrackingAuthorizationStatus == .authorizedWhenInUse {
                        Picker("Duration", selection: $routeTrackingDuration) {
                            ForEach(TemporaryRouteTrackingDuration.allCases) { duration in
                                Text(duration.title)
                                    .tag(duration)
                            }
                        }
                        .pickerStyle(.menu)

                        Toggle("Turn off at 50% battery", isOn: routeTrackingStopsAtBatteryFiftyBinding)
                        Toggle("Turn off in Low Power Mode", isOn: routeTrackingStopsInLowPowerModeBinding)
                        Toggle("Notify when tracking stops", isOn: routeTrackingStopNotificationBinding)

                        Text("These safeguards can end the session early if power gets tight.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        Text("iOS asks for notification permission the first time. If notifications are blocked, open Settings to allow them.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        Button {
                            captureManager.enableTemporaryRouteTracking(duration: routeTrackingDuration)
                        } label: {
                            Label(
                                routeTrackingEndsAt == nil
                                ? "Enable real route tracking"
                                : "Update route tracking",
                                systemImage: "location.fill.viewfinder"
                            )
                        }

                        if let endsAt = routeTrackingEndsAt,
                           endsAt > .now {
                            Text("Auto-off \(routeTrackingDuration.availabilityText).")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)

                            Button("Turn off now", role: .destructive) {
                                captureManager.disableTemporaryRouteTracking()
                            }
                        }

                        if routeTrackingAuthorizationStatus == .authorizedWhenInUse {
                            Text("Always location access is needed to keep this running in the background.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Grant location access first to use this feature.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelSurface()
            }
        }
        .onReceive(captureManager.$temporaryRouteTrackingDuration.removeDuplicates()) { routeTrackingDuration = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingEndsAt.removeDuplicates()) { routeTrackingEndsAt = $0 }
        .onReceive(captureManager.$authorizationStatus.removeDuplicates()) { routeTrackingAuthorizationStatus = $0 }
        .onReceive(captureManager.$lastErrorMessage.removeDuplicates()) { routeTrackingLastErrorMessage = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopsAtFiftyPercentBattery.removeDuplicates()) { routeTrackingStopsAtFiftyPercentBattery = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopsInLowPowerMode.removeDuplicates()) { routeTrackingStopsInLowPowerMode = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopNotificationEnabled.removeDuplicates()) { routeTrackingStopNotificationEnabled = $0 }
        .alert("Notification Access", isPresented: $isShowingNotificationPermissionAlert) {
            Button("Open Settings") {
                openURL(URL(string: UIApplication.openSettingsURLString)!)
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Moves needs notification permission to send a stop alert. You can allow it in Settings.")
        }
    }
}
