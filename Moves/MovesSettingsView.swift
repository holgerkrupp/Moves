//
//  MovesSettingsView.swift
//  Raul
//
//  Settings screen extracted from ContentView.
//

import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MovesSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let dayTimelines: [DayTimeline]
    let selectedDayKey: String
    @ObservedObject var captureManager: MovesLocationCaptureManager

    @State private var routeTrackingDuration: TemporaryRouteTrackingDuration
    @State private var isExporting = false
    @State private var exportDocument: TimelineExportDocument?
    @State private var exportContentType: UTType = .xml
    @State private var exportFilename = "moves-export"
    @State private var exportMessage = ""
    @State private var isShowingExportMessage = false

    init(
        dayTimelines: [DayTimeline],
        selectedDayKey: String,
        captureManager: MovesLocationCaptureManager
    ) {
        self.dayTimelines = dayTimelines
        self.selectedDayKey = selectedDayKey
        _captureManager = ObservedObject(wrappedValue: captureManager)
        _routeTrackingDuration = State(initialValue: captureManager.temporaryRouteTrackingDuration)
    }

    private var selectedDay: DayTimeline? {
        dayTimelines.first(where: { $0.dayKey == selectedDayKey })
    }

    private var selectedDayExportLabel: String {
        if let selectedDay {
            return localizedExportDateString(selectedDay.dayStart)
        }
        return "Selected Day"
    }

    private func localizedExportDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM y")
        return formatter.string(from: date)
    }

    private var dayCount: Int {
        dayTimelines.count
    }

    private var placeCount: Int {
        dayTimelines.reduce(0) { $0 + $1.places.count }
    }

    private var moveCount: Int {
        dayTimelines.reduce(0) { $0 + $1.moves.count }
    }

    private var sampleCount: Int {
        dayTimelines.reduce(0) { $0 + $1.samples.count }
    }

    private var routeTrackingStopsAtBatteryFiftyBinding: Binding<Bool> {
        Binding(
            get: { captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery },
            set: { newValue in
                captureManager.updateTemporaryRouteTrackingAutoStopRules(
                    stopsAtFiftyPercentBattery: newValue,
                    stopsInLowPowerMode: captureManager.temporaryRouteTrackingStopsInLowPowerMode
                )
            }
        )
    }

    private var routeTrackingStopsInLowPowerModeBinding: Binding<Bool> {
        Binding(
            get: { captureManager.temporaryRouteTrackingStopsInLowPowerMode },
            set: { newValue in
                captureManager.updateTemporaryRouteTrackingAutoStopRules(
                    stopsAtFiftyPercentBattery: captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery,
                    stopsInLowPowerMode: newValue
                )
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if let bannerData = trackingStatusBannerData(
                    for: captureManager,
                    context: .settings
                ) {
                    Section {
                        TrackingStatusBanner(data: bannerData)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }

                if !captureManager.isDemoMode {
                    Section("Real Route Tracking") {
                        Text("Use frequent GPS updates for the actual route when you need more detail. Battery use increases while this is on.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        if captureManager.authorizationStatus == .authorizedAlways ||
                            captureManager.authorizationStatus == .authorizedWhenInUse {
                            Picker("Duration", selection: $routeTrackingDuration) {
                                ForEach(TemporaryRouteTrackingDuration.allCases) { duration in
                                    Text(duration.title)
                                        .tag(duration)
                                }
                            }
                            .pickerStyle(.menu)

                            Toggle("Turn off at 50% battery", isOn: routeTrackingStopsAtBatteryFiftyBinding)
                            Toggle("Turn off in Low Power Mode", isOn: routeTrackingStopsInLowPowerModeBinding)

                            Text("These safeguards can end the session early if power gets tight.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)

                            Button {
                                captureManager.enableTemporaryRouteTracking(duration: routeTrackingDuration)
                            } label: {
                                Label(
                                    captureManager.temporaryRouteTrackingEndsAt == nil
                                    ? "Enable real route tracking"
                                    : "Update route tracking",
                                    systemImage: "location.fill.viewfinder"
                                )
                            }

                            if let endsAt = captureManager.temporaryRouteTrackingEndsAt,
                               endsAt > .now {
                                Text("Auto-off \(captureManager.temporaryRouteTrackingDuration.availabilityText).")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)

                                Button("Turn off now", role: .destructive) {
                                    captureManager.disableTemporaryRouteTracking()
                                }
                            }

                            if captureManager.authorizationStatus == .authorizedWhenInUse {
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
                }

                Section("Data Summary") {
                    LabeledContent("Days", value: "\(dayCount)")
                    LabeledContent("Places", value: "\(placeCount)")
                    LabeledContent("Moves", value: "\(moveCount)")
                    LabeledContent("Samples", value: "\(sampleCount)")
                }

                Section("GPX Export") {
                    Button {
                        export(.gpx, scope: .selectedDay)
                    } label: {
                        Label("\(selectedDayExportLabel) (.gpx)", systemImage: "calendar")
                    }
                    .disabled(selectedDay == nil)

                    Button {
                        export(.gpx, scope: .allDays)
                    } label: {
                        Label("All Days (.gpx)", systemImage: "calendar.badge.clock")
                    }
                    .disabled(dayTimelines.isEmpty)
                }

                Section("Other Formats") {
                    Button {
                        export(.geoJSON, scope: .selectedDay)
                    } label: {
                        Label("\(selectedDayExportLabel) (.geojson)", systemImage: "map")
                    }
                    .disabled(selectedDay == nil)

                    Button {
                        export(.geoJSON, scope: .allDays)
                    } label: {
                        Label("All Days (.geojson)", systemImage: "map.fill")
                    }
                    .disabled(dayTimelines.isEmpty)

                    Button {
                        export(.csv, scope: .allDays)
                    } label: {
                        Label("All Days Places+Moves (.csv)", systemImage: "tablecells")
                    }
                    .disabled(dayTimelines.isEmpty)
                }
                CreatedByView()
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
            .onChange(of: captureManager.temporaryRouteTrackingDuration) { _, newValue in
                routeTrackingDuration = newValue
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
            .alert("Export", isPresented: $isShowingExportMessage) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportMessage)
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
}
