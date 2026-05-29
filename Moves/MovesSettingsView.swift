//
//  MovesSettingsView.swift
//  Raul
//
//  Settings screen extracted from ContentView.
//

import Foundation
import Combine
import CoreLocation
import HealthKit
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
                    
                    SettingsCard(title: "Other Export Formats") {
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

                    SettingsCard(title: "Import") {
                        NavigationLink {
                            HealthWorkoutRouteImportSettingsView()
                        } label: {
                            SettingsNavigationRow(
                                title: "Apple Health workout routes",
                                systemImage: "figure.run",
                                status: HKHealthStore.isHealthDataAvailable() ? nil : "Unavailable"
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            RouteFileImportSettingsView(modelContext: modelContext)
                        } label: {
                            SettingsNavigationRow(
                                title: "Files (GPX, TCX, KML, GeoJSON)",
                                systemImage: "square.and.arrow.down",
                                status: nil
                            )
                        }
                        .buttonStyle(.plain)

                        Text("Imports GPS tracks from running, cycling, walking, and hiking workouts. Existing phone or watch points are deduplicated automatically.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
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

struct RouteTrackingSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let captureManager: MovesLocationCaptureManager

    var body: some View {
        NavigationStack {
            ScrollView {
                RouteTrackingSettingsSection(captureManager: captureManager)
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
            .navigationTitle("Real Route Tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct HealthWorkoutRouteImportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var healthRouteImportManager: HealthWorkoutRouteAutoImportManager
    @AppStorage(HealthWorkoutRouteImportSettings.isEnabledKey) private var isEnabled = false

    @State private var importMessage = ""
    @State private var isShowingImportMessage = false

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: {
                isEnabled = $0
                notifySettingsChanged()
            }
        )
    }

    private var isHealthAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                SettingsCard(title: "Apple Health Routes") {
                    Toggle("Use Apple Health workout routes", isOn: isEnabledBinding)
                        .disabled(!isHealthAvailable || healthRouteImportManager.isHistoricalImporting)

                    Text(statusText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "Legacy Import") {
                    Button {
                        importAllRoutes()
                    } label: {
                        Label {
                            Text(importAllButtonTitle)
                                .frame(maxWidth: .infinity)
                        } icon: {
                            Image(systemName: importAllButtonSystemImage)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .tint(isImporting ? .red : MovesPalette.routeTracking)
                    .disabled(!isHealthAvailable && !isImporting)

                    if isImporting {
                        ProgressView()
                            .tint(MovesPalette.routeTracking)

                        if !healthRouteImportManager.historicalImportProgressText.isEmpty {
                            Text(healthRouteImportManager.historicalImportProgressText)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(importAllHelpText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
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
        .navigationTitle("Apple Health Routes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .alert("Apple Health Routes", isPresented: $isShowingImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
        .onChange(of: healthRouteImportManager.isHistoricalImporting) { wasImporting, isImporting in
            guard wasImporting, !isImporting else { return }
            showHistoricalImportResultIfAvailable()
        }
    }

    private var statusText: String {
        guard isHealthAvailable else {
            return "Health data is not available on this device."
        }

        if isEnabled {
            return "Moves can import supported workout GPS routes from Apple Health. Turn this off to stop future Health route imports."
        }

        return "Turn this on to allow workout route imports. Already imported routes remain in the timeline until you remove or deduplicate timeline data."
    }

    private var importAllButtonTitle: String {
        if isImporting {
            return "Cancel Import"
        }

        if HealthWorkoutRouteImporter.hasInterruptedHistoricalImport {
            return "Resume workout route import"
        }

        return "Import all workout routes"
    }

    private var importAllButtonSystemImage: String {
        isImporting ? "pause.circle.fill" : "tray.and.arrow.down.fill"
    }

    private var importAllHelpText: String {
        if isImporting {
            return "The import keeps running if you leave this screen. If iOS pauses the app in the background, progress is saved and the next launch resumes automatically."
        }

        if HealthWorkoutRouteImporter.hasInterruptedHistoricalImport {
            return "A previous historical import was interrupted. Resume continues from the last checked workout instead of starting over."
        }

        return "Import all asks Apple Health for every supported workout route it can return. If iOS pauses the app, progress is saved and the next import resumes from there."
    }

    private func notifySettingsChanged() {
        NotificationCenter.default.post(
            name: HealthWorkoutRouteImportSettings.didChangeNotification,
            object: nil
        )
    }

    @MainActor
    private func importAllRoutes() {
        if isImporting {
            healthRouteImportManager.cancelHistoricalImport()
            return
        }

        healthRouteImportManager.startHistoricalImportIfNeeded()
    }

    private var isImporting: Bool {
        healthRouteImportManager.isHistoricalImporting
    }

    private func showHistoricalImportResultIfAvailable() {
        if let report = healthRouteImportManager.lastHistoricalImportReport {
            let prefix = report.didResumeInterruptedImport ? "Resumed and imported" : "Imported"
            importMessage = "\(prefix) \(report.routeCount) workout route(s) from \(report.workoutCount) workout(s), covering \(report.sampleCount) GPS point(s). Duplicate phone and watch points were merged automatically."
            isShowingImportMessage = true
        } else if let message = healthRouteImportManager.lastHistoricalImportErrorMessage {
            importMessage = message
            isShowingImportMessage = true
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

private struct SettingsNavigationRow: View {
    let title: String
    let systemImage: String
    let status: String?

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)

            Spacer(minLength: 8)

            if let status {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}

@MainActor
private func routeTrackingBannerData(
    authorizationStatus: CLAuthorizationStatus,
    lastErrorMessage: String?,
    duration: TemporaryRouteTrackingDuration,
    endsAt: Date?,
    stopsAtFiftyPercentBattery: Bool,
    stopsInLowPowerMode: Bool,
    isBackgroundLocationListeningEnabled: Bool,
    context: TrackingStatusBannerContext
) -> TrackingStatusBannerData? {
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
        if !isBackgroundLocationListeningEnabled {
            return TrackingStatusBannerData(
                title: "Background tracking is off",
                message: "Moves will not listen for visits or significant location changes until you turn it on again or start real route tracking.",
                systemImage: "location.slash",
                tint: .secondary
            )
        }

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
    @State private var isBackgroundLocationListeningEnabled: Bool
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
        _isBackgroundLocationListeningEnabled = State(
            initialValue: captureManager.isBackgroundLocationListeningEnabled
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
            authorizationStatus: routeTrackingAuthorizationStatus,
            lastErrorMessage: routeTrackingLastErrorMessage,
            duration: routeTrackingDuration,
            endsAt: routeTrackingEndsAt,
            stopsAtFiftyPercentBattery: routeTrackingStopsAtFiftyPercentBattery,
            stopsInLowPowerMode: routeTrackingStopsInLowPowerMode,
            isBackgroundLocationListeningEnabled: isBackgroundLocationListeningEnabled,
            context: .settings
        )
    }

    private var isRouteTrackingActive: Bool {
        guard let routeTrackingEndsAt else { return false }
        return routeTrackingEndsAt > .now
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

            VStack(alignment: .leading, spacing: 12) {
                Text("Tracking Modes")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Toggle(
                    "Listen for location changes",
                    isOn: $isBackgroundLocationListeningEnabled
                )
                .font(.system(size: 15, weight: .semibold, design: .rounded))

                Text("Background tracking uses iOS visit monitoring and significant location changes to record places and movement with low energy use. When this is off, Moves stops background listening until you turn it on again or start temporary route tracking.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface()

            VStack(alignment: .leading, spacing: 10) {
                Text("Real Route Tracking")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("Use frequent GPS updates for the actual route when you need more detail. Battery use increases while this is on.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                if routeTrackingAuthorizationStatus == .authorizedAlways ||
                    routeTrackingAuthorizationStatus == .authorizedWhenInUse {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Duration")
                                .gridColumnAlignment(.leading)

                            Menu {
                                ForEach(TemporaryRouteTrackingDuration.allCases) { duration in
                                    Button {
                                        routeTrackingDuration = duration
                                    } label: {
                                        if routeTrackingDuration == duration {
                                            Label(duration.title, systemImage: "checkmark")
                                        } else {
                                            Text(duration.title)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(routeTrackingDuration.title)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                            }
                            .buttonStyle(.bordered)
                            .gridColumnAlignment(.trailing)
                        }

                        GridRow {
                            Text("Turn off at 50% battery")

                            Toggle("Turn off at 50% battery", isOn: routeTrackingStopsAtBatteryFiftyBinding)
                                .labelsHidden()
                        }

                        GridRow {
                            Text("Turn off in Low Power Mode")

                            Toggle("Turn off in Low Power Mode", isOn: routeTrackingStopsInLowPowerModeBinding)
                                .labelsHidden()
                        }

                        GridRow {
                            Text("Notify when tracking stops")

                            Toggle("Notify when tracking stops", isOn: routeTrackingStopNotificationBinding)
                                .labelsHidden()
                        }
                    }
                    .font(.system(size: 15, weight: .medium, design: .rounded))

                    Text("These safeguards can end the session early if power gets tight.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text("iOS asks for notification permission the first time. If notifications are blocked, open Settings to allow them.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Button {
                        if isRouteTrackingActive {
                            captureManager.disableTemporaryRouteTracking()
                        } else {
                            captureManager.enableTemporaryRouteTracking(duration: routeTrackingDuration)
                        }
                    } label: {
                        Label(
                            isRouteTrackingActive
                            ? "Turn off"
                            : "Enable real route tracking",
                            systemImage: isRouteTrackingActive
                            ? "location.slash"
                            : "location.fill.viewfinder"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .tint(isRouteTrackingActive ? .red : nil)

                    if isRouteTrackingActive {
                        Text("Auto-off \(routeTrackingDuration.availabilityText).")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
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
        .onReceive(captureManager.$temporaryRouteTrackingDuration.removeDuplicates()) { routeTrackingDuration = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingEndsAt.removeDuplicates()) { routeTrackingEndsAt = $0 }
        .onReceive(captureManager.$authorizationStatus.removeDuplicates()) { routeTrackingAuthorizationStatus = $0 }
        .onReceive(captureManager.$lastErrorMessage.removeDuplicates()) { routeTrackingLastErrorMessage = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopsAtFiftyPercentBattery.removeDuplicates()) { routeTrackingStopsAtFiftyPercentBattery = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopsInLowPowerMode.removeDuplicates()) { routeTrackingStopsInLowPowerMode = $0 }
        .onReceive(captureManager.$temporaryRouteTrackingStopNotificationEnabled.removeDuplicates()) { routeTrackingStopNotificationEnabled = $0 }
        .onReceive(captureManager.$isBackgroundLocationListeningEnabled.removeDuplicates()) { isBackgroundLocationListeningEnabled = $0 }
        .onChange(of: isBackgroundLocationListeningEnabled) { _, isEnabled in
            captureManager.setBackgroundLocationListeningEnabled(isEnabled)
        }
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
