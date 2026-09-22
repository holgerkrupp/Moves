import CoreLocation
import CoreTransferable
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum TrackingPromptAction {
    case requestAuthorization
    case openSettings
}

private struct TrackingPermissionPrompt {
    let title: String
    let message: String
    let buttonTitle: String?
    let action: TrackingPromptAction?
}

enum TrackingStatusBannerContext {
    case timeline
    case settings
}

enum LandscapeLayoutSettings {
    static let controlsOnLeftKey = "landscapeControlsOnLeft"

    static func isLandscapePhone(_ size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone && size.width > size.height
    }

    static func controlPaneWidth(for size: CGSize) -> CGFloat {
        min(max(size.width * 0.42, 300), 390)
    }
}

struct LandscapeSplitView<MapPane: View, ControlPane: View>: View {
    @AppStorage(LandscapeLayoutSettings.controlsOnLeftKey) private var controlsOnLeft = false

    let spacing: CGFloat
    @ViewBuilder let mapPane: () -> MapPane
    @ViewBuilder let controlPane: () -> ControlPane

    init(
        spacing: CGFloat = 10,
        @ViewBuilder mapPane: @escaping () -> MapPane,
        @ViewBuilder controlPane: @escaping () -> ControlPane
    ) {
        self.spacing = spacing
        self.mapPane = mapPane
        self.controlPane = controlPane
    }

    var body: some View {
        GeometryReader { proxy in
            let controlWidth = LandscapeLayoutSettings.controlPaneWidth(for: proxy.size)

            HStack(spacing: spacing) {
                if controlsOnLeft {
                    controlPane()
                        .frame(width: controlWidth)
                    mapPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    mapPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    controlPane()
                        .frame(width: controlWidth)
                }
            }
        }
    }
}

struct LandscapePaneSideButton: View {
    @AppStorage(LandscapeLayoutSettings.controlsOnLeftKey) private var controlsOnLeft = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                controlsOnLeft.toggle()
            }
        } label: {
            Label(
                controlsOnLeft ? "Put controls on right" : "Put controls on left",
                systemImage: controlsOnLeft
                    ? "rectangle.righthalf.inset.filled"
                    : "rectangle.lefthalf.inset.filled"
            )
            .labelStyle(.iconOnly)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frostedCircle(enabled: true)
        .accessibilityLabel(controlsOnLeft ? "Put controls on right" : "Put controls on left")
        .help(controlsOnLeft ? "Put controls on right" : "Put controls on left")
    }
}

struct TrackingStatusBannerData {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    let buttonTitle: String?
    let buttonRole: ButtonRole?

    init(
        title: String,
        message: String,
        systemImage: String,
        tint: Color,
        buttonTitle: String? = nil,
        buttonRole: ButtonRole? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.buttonTitle = buttonTitle
        self.buttonRole = buttonRole
    }
}

struct TrackingStatusBanner: View {
    let data: TrackingStatusBannerData
    let buttonAction: (() -> Void)?

    init(
        data: TrackingStatusBannerData,
        buttonAction: (() -> Void)? = nil
    ) {
        self.data = data
        self.buttonAction = buttonAction
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: data.systemImage)
                .foregroundStyle(data.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(data.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Text(data.message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let buttonTitle = data.buttonTitle,
               let buttonAction {
                Button(buttonTitle, role: data.buttonRole) {
                    buttonAction()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

@MainActor
func trackingStatusBannerData(
    for captureManager: MovesLocationCaptureManager,
    context: TrackingStatusBannerContext
) -> TrackingStatusBannerData? {
    guard captureManager.isLocationTrackingAvailable else { return nil }

    if captureManager.isDemoMode {
        return nil
    }

    if let lastErrorMessage = captureManager.lastErrorMessage {
        return TrackingStatusBannerData(
            title: "Location tracking error",
            message: lastErrorMessage,
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
        )
    }

    if let endsAt = captureManager.temporaryRouteTrackingEndsAt,
       endsAt > .now {
        switch captureManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return TrackingStatusBannerData(
                title: "Real route tracking on",
                message: temporaryRouteTrackingBannerMessage(
                    for: captureManager,
                    context: context
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

    if !captureManager.isBackgroundLocationListeningEnabled {
        switch captureManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return TrackingStatusBannerData(
                title: "Location tracking is turned off",
                message: "Moves is not listening for visits or significant location changes. Turn it back on in Route Tracking settings.",
                systemImage: "location.slash",
                tint: .secondary
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

    switch captureManager.authorizationStatus {
    case .authorizedAlways:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Background tracking is enabled.",
            systemImage: "location.fill",
            tint: MovesPalette.place
        )
    case .authorizedWhenInUse:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Moves can read location while open. Grant Always to keep recording in the background.",
            systemImage: "location.fill",
            tint: MovesPalette.start
        )
    case .notDetermined:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Allow location access to start recording on this device.",
            systemImage: "location.slash",
            tint: .secondary
        )
    case .denied:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Enable location in Settings if you want Moves to record visits and movement.",
            systemImage: "location.slash",
            tint: .secondary
        )
    case .restricted:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
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

@MainActor
private func temporaryRouteTrackingBannerMessage(
    for captureManager: MovesLocationCaptureManager,
    context: TrackingStatusBannerContext
) -> String {
    let durationText = captureManager.temporaryRouteTrackingDuration.availabilityText
    let autoStopText = temporaryRouteTrackingAutoStopText(for: captureManager)

    switch captureManager.authorizationStatus {
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

@MainActor
private func temporaryRouteTrackingAutoStopText(
    for captureManager: MovesLocationCaptureManager
) -> String {
    let stopAtBatteryFifty = captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery
    let stopInLowPowerMode = captureManager.temporaryRouteTrackingStopsInLowPowerMode

    switch (stopAtBatteryFifty, stopInLowPowerMode) {
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

struct ContentView: View {
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @EnvironmentObject private var routeFileImporter: RouteFileImporter
    @EnvironmentObject private var importCoordinator: ImportCoordinator
    @EnvironmentObject private var undoController: AppUndoController
    @EnvironmentObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @EnvironmentObject private var multiDevicePresenceManager: MultiDevicePresenceManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Query(sort: \DayTimeline.dayStart, order: .forward)
    private var dayTimelines: [DayTimeline]

    @State private var selectedDayKey = ""
    @State private var selectedPageIndex = 0
    @State private var isShowingSettings = false
    @State private var isShowingRouteTrackingSettings = false
    @State private var isShowingDatePicker = false
    @State private var timelineColumnVisibility = NavigationSplitViewVisibility.all
    @State private var timelineMapSelection: TimelineMapSelection?
    @State private var pendingRouteImportURLs: [URL] = []
    @State private var routeImportFlushTask: Task<Void, Never>?
    @State private var isShowingDroppedRouteImportOptions = false
    @State private var droppedRouteImportConfiguration = RouteFileImportConfiguration()
    @State private var isShowingImportQueue = false

    private var selectedDay: DayTimeline? {
        guard dayTimelines.indices.contains(selectedPageIndex) else { return nil }
        return dayTimelines[selectedPageIndex]
    }

    private var canGoOlder: Bool {
        dayTimelines.indices.contains(selectedPageIndex) && selectedPageIndex > 0
    }

    private var canGoNewer: Bool {
        dayTimelines.indices.contains(selectedPageIndex) && selectedPageIndex < dayTimelines.count - 1
    }

    private var cloudDataPresenceCountSignature: String {
        let placeCount = dayTimelines.reduce(0) { $0 + $1.places.count }
        let moveCount = dayTimelines.reduce(0) { $0 + $1.moves.count }
        return "\(placeCount)|\(moveCount)"
    }

    private var spotlightPlaceSignature: [String] {
        dayTimelines
            .flatMap(\.places)
            .map { place in
                [
                    place.id.uuidString,
                    place.userLabel ?? "",
                    place.autoLabel ?? "",
                    String(place.arrivalDate.timeIntervalSinceReferenceDate),
                ].joined(separator: "|")
            }
            .sorted()
    }

    var body: some View {
        ZStack {
            if usesSplitNavigation {
                timelineSplitWorkspace
            } else {
                NavigationStack {
                    compactTimelineContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .sheet(isPresented: $isShowingSettings) {
            MovesSettingsView(
                dayTimelines: dayTimelines,
                selectedDayKey: selectedDayKey,
                captureManager: captureManager,
                routeFileImporter: routeFileImporter,
                importCoordinator: importCoordinator,
                modelContext: modelContext
            )
        }
        .sheet(isPresented: $isShowingRouteTrackingSettings) {
            RouteTrackingSettingsSheet(captureManager: captureManager)
        }
        .sheet(isPresented: $isShowingDatePicker) {
            datePickerSheet
        }
        .sheet(isPresented: $isShowingDroppedRouteImportOptions, onDismiss: {
            pendingRouteImportURLs.removeAll()
        }) {
            RouteFileImportOptionsView(
                configuration: $droppedRouteImportConfiguration,
                actionTitle: "Import Dropped Items",
                actionSystemImage: "square.and.arrow.down"
            ) {
                let urls = pendingRouteImportURLs
                pendingRouteImportURLs.removeAll()
                isShowingDroppedRouteImportOptions = false
                Task { @MainActor in
                    await Task.yield()
                    importCoordinator.enqueueRouteFiles(urls, configuration: droppedRouteImportConfiguration)
                }
            }
        }
        .sheet(isPresented: $isShowingImportQueue) {
            ImportQueueView(coordinator: importCoordinator) { _ in
                importCoordinator.resumeRouteImport()
            } onPause: { _ in
                importCoordinator.pauseRouteImport()
            } onCancel: { _ in
                importCoordinator.cancelRouteImport()
            }
            .presentationDetents([.medium, .large])
        }
        .alert(
            "Use this device for tracking?",
            isPresented: $multiDevicePresenceManager.shouldChooseLocationRole
        ) {
            Button("Enable tracking") {
                multiDevicePresenceManager.choose(.tracking, captureManager: captureManager)
            }
            Button("Not now") {
                multiDevicePresenceManager.choose(.management, captureManager: captureManager)
            }
        } message: {
            Text(multiDevicePresenceManager.promptMessage)
        }
        .task {
            guard !ProcessInfo.processInfo.isRunningForPreviews else { return }
            if captureManager.isLocationTrackingAvailable {
                multiDevicePresenceManager.refreshPresence()
                await captureManager.start()
            }
        }
        .onAppear {
            openCurrentDay()
            repairDuplicateDayTimelinesIfNeeded()
            modelContext.undoManager = undoController.manager
            publishWidgetSnapshot()
            refreshSpotlightIndex()
            cloudDataPresencePublisher.publishSoon()
        }
        .onChange(of: dayTimelines.map(\.dayKey)) { _, _ in
            repairDuplicateDayTimelinesIfNeeded()
            syncSelectedDayIfNeeded()
            publishWidgetSnapshot()
        }
        .onChange(of: selectedDay?.moves.count ?? 0) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: selectedDay?.places.count ?? 0) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: cloudDataPresenceCountSignature) { _, _ in
            cloudDataPresencePublisher.publishSoon()
        }
        .onChange(of: spotlightPlaceSignature) { _, _ in
            refreshSpotlightIndex()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            if captureManager.isLocationTrackingAvailable {
                multiDevicePresenceManager.refreshPresence()
            }
            openCurrentDay()
            publishWidgetSnapshot()
            refreshSpotlightIndex()
            cloudDataPresencePublisher.publishSoon()
        }
        .onOpenURL(perform: handleDeepLink)
        .dropDestination(for: RouteFileDropItem.self) { items, _ in
            enqueueRouteImport(items.map(\.url))
        }
        .onChange(of: selectedPageIndex) { _, newIndex in
            guard dayTimelines.indices.contains(newIndex) else { return }
            selectedDayKey = dayTimelines[newIndex].dayKey
        }
        .onChange(of: selectedDayKey) { _, newKey in
            timelineMapSelection = nil
            guard let index = dayTimelines.firstIndex(where: { $0.dayKey == newKey }),
                  index != selectedPageIndex else { return }
            selectedPageIndex = index
        }
        .overlay {
            ShakeToUndoDetector(undoManager: undoController.manager) {
                handleShakeToUndo()
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
        }
        .focusedSceneValue(
            \.movesCommandActions,
            MovesCommandActions(
                showSettings: { isShowingSettings = true },
                chooseDate: { isShowingDatePicker = true },
                selectToday: openCurrentDay,
                selectOlderDay: selectOlderDay,
                selectNewerDay: selectNewerDay,
                canSelectOlderDay: canGoOlder,
                canSelectNewerDay: canGoNewer
            )
        )
    }

    private var usesSplitNavigation: Bool {
        horizontalSizeClass == .regular
    }

    private var timelineSplitWorkspace: some View {
        NavigationSplitView(columnVisibility: $timelineColumnVisibility) {
            recentDatesSidebar
        } detail: {
            NavigationStack {
                compactTimelineContent
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var recentDatesSidebar: some View {
        List(selection: daySidebarSelection) {
            Section("Recent Dates") {
                ForEach(recentDayTimelines) { day in
                    DaySidebarRow(day: day)
                        .tag(day.dayKey)
                }
            }
        }
        .navigationTitle("Moves")
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 320)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingDatePicker = true
                } label: {
                    Label("Choose Date", systemImage: "calendar")
                }
            }
        }
    }

    private var recentDayTimelines: [DayTimeline] {
        Array(dayTimelines.suffix(60).reversed())
    }

    private var daySidebarSelection: Binding<String?> {
        Binding(
            get: { selectedDayKey.isEmpty ? nil : selectedDayKey },
            set: { selectedDayKey = $0 ?? selectedDayKey }
        )
    }

    private var compactTimelineContent: some View {
        ZStack {
            background

            VStack(spacing: 12) {
                if captureManager.isLocationTrackingAvailable {
                    if let trackingPermissionPrompt {
                        trackingPermissionBanner(trackingPermissionPrompt)
                            .safeAreaPadding(.horizontal, 14)
                    }

                    if let bannerData = trackingStatusBannerData(
                        for: captureManager,
                        context: .timeline
                    ) {
                        TrackingStatusBanner(
                            data: bannerData,
                            buttonAction: {
                                captureManager.disableTemporaryRouteTracking()
                            }
                        )
                        .safeAreaPadding(.horizontal, 14)
                    }
                }

                if dayTimelines.isEmpty {
                    emptyState
                        .safeAreaPadding(.horizontal, 14)
                } else {
                    dayHeader
                        .safeAreaPadding(.horizontal, 14)
                        .padding(.top, 10)

                    TabView(selection: $selectedPageIndex) {
                        ForEach(Array(dayTimelines.enumerated()), id: \.element.dayKey) { index, day in
                            DayTimelinePage(
                                dayKey: day.dayKey,
                                isActive: index == selectedPageIndex,
                                mapSelection: $timelineMapSelection
                            )
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
        .navigationTitle("Moves")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings")
            }

            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    MovesStatisticsSearchView(
                        dayTimelines: dayTimelines,
                        initialDate: selectedDay?.dayStart ?? .now
                    )
                } label: {
                    Label("Statistics & Share", systemImage: "chart.bar.xaxis")
                }
                .help("Statistics & Share")
            }

            ToolbarItem(placement: .topBarTrailing) {
                ImportQueueToolbarButton(
                    coordinator: importCoordinator,
                    isPresented: $isShowingImportQueue
                )
            }

            if captureManager.isLocationTrackingAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    RouteTrackingToolbarButton(
                        endsAt: captureManager.temporaryRouteTrackingEndsAt,
                        authorizationStatus: captureManager.authorizationStatus,
                        tapAction: {
                            isShowingRouteTrackingSettings = true
                        },
                        longPressAction: {
                            captureManager.enableTemporaryRouteTracking(
                                duration: captureManager.temporaryRouteTrackingDuration
                            )
                        }
                    )
                }
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func trackingPermissionBanner(_ prompt: TrackingPermissionPrompt) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "location.circle.fill")
                .foregroundStyle(MovesPalette.start)

            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Text(prompt.message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let buttonTitle = prompt.buttonTitle,
               let action = prompt.action {
                Button(buttonTitle) {
                    performTrackingPromptAction(action)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .panelSurface()
    }

    private var dayHeader: some View {
        HStack(spacing: 10) {
            Button {
                selectOlderDay()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .frostedCircle(enabled: canGoOlder)
            .hoverEffect(.highlight)
            .disabled(!canGoOlder)

            VStack(spacing: 2) {
                if let selectedDay {
                    Button {
                        isShowingDatePicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedDay.dayStart, format: .dateTime.weekday(.wide).day().month(.wide))
                            if selectedDay.hasImportedRouteData {
                                Image(systemName: "tray.and.arrow.down.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(MovesPalette.routeTracking)
                                    .accessibilityLabel("Contains imported data")
                            }
                        }
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.92))
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)

                    Text("\(selectedDay.uniqueLocationCount) places   \(selectedDay.moves.count) moves")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                selectNewerDay()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .frostedCircle(enabled: canGoNewer)
            .hoverEffect(.highlight)
            .disabled(!canGoNewer)
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "location.slash.circle")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)

            Text("No timeline yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Keep Moves running in the background. Visits and movement segments appear as iOS records them.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .panelSurface()
    }

    private var trackingPermissionPrompt: TrackingPermissionPrompt? {
        guard captureManager.isLocationTrackingAvailable else { return nil }

        if captureManager.isDemoMode {
            return nil
        }

        // Location permission is only relevant after the user has opted this
        // device into tracking.
        guard captureManager.isTrackingRoleDecided,
              captureManager.isBackgroundLocationListeningEnabled else {
            return nil
        }

        switch captureManager.authorizationStatus {
        case .notDetermined:
            return TrackingPermissionPrompt(
                title: "Enable location tracking",
                message: "Moves needs location access to record your timeline. We will ask for While Using first, then immediately request Always for background tracking.",
                buttonTitle: "Allow Location Access",
                action: .requestAuthorization
            )
        case .authorizedWhenInUse:
            return TrackingPermissionPrompt(
                title: "Allow Always for background tracking",
                message: "We can already read your location while the app is open. Tap below to switch to Always so Moves can keep recording in the background.",
                buttonTitle: "Continue to Always",
                action: .requestAuthorization
            )
        case .denied:
            return TrackingPermissionPrompt(
                title: "Location access is off",
                message: "Moves needs location access to record visits and movement. Open Settings to allow it.",
                buttonTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            return TrackingPermissionPrompt(
                title: "Location access is restricted",
                message: "This device does not allow location access for Moves.",
                buttonTitle: nil,
                action: nil
            )
        case .authorizedAlways:
            return nil
        @unknown default:
            return nil
        }
    }

    private func performTrackingPromptAction(_ action: TrackingPromptAction) {
        switch action {
        case .requestAuthorization:
            captureManager.requestTrackingAuthorization()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
    }

    private func openCurrentDay() {
        guard !ProcessInfo.processInfo.isRunningForPreviews else { return }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        let todayKey = DayTimeline.makeDayKey(for: todayStart)

        #if targetEnvironment(macCatalyst)
        // Catalyst is a review/import client. Never manufacture placeholder records while
        // CloudKit is still populating a fresh local store.
        if let todayIndex = dayTimelines.firstIndex(where: { $0.dayKey == todayKey }) {
            selectedDayKey = todayKey
            selectedPageIndex = todayIndex
        } else if let latestIndex = dayTimelines.indices.last {
            selectedDayKey = dayTimelines[latestIndex].dayKey
            selectedPageIndex = latestIndex
        }
        return
        #endif

        var existingKeys = Set(dayTimelines.map(\.dayKey))
        var didInsertDay = false

        if !existingKeys.contains(todayKey) {
            modelContext.insert(DayTimeline(dayStart: todayStart))
            existingKeys.insert(todayKey)
            didInsertDay = true
        }

        // Days without any recorded location have no timeline of their own, which made paging
        // skip them entirely. Fill the gaps so every day since the first recording is reachable.
        if let earliestDayStart = dayTimelines.first?.dayStart {
            var dayStart = calendar.startOfDay(for: earliestDayStart)

            while dayStart < todayStart {
                let dayKey = DayTimeline.makeDayKey(for: dayStart)
                if !existingKeys.contains(dayKey) {
                    modelContext.insert(DayTimeline(dayStart: dayStart))
                    existingKeys.insert(dayKey)
                    didInsertDay = true
                }

                guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
                dayStart = nextDayStart
            }
        }

        if didInsertDay {
            do {
                try modelContext.save()
            } catch {
                print("Failed to create day timelines: \(error.localizedDescription)")
            }
        }

        selectedDayKey = todayKey
        if let todayIndex = dayTimelines.firstIndex(where: { $0.dayKey == todayKey }) {
            selectedPageIndex = todayIndex
        }
    }

    private func repairDuplicateDayTimelinesIfNeeded() {
        let hasDuplicates = Dictionary(grouping: dayTimelines, by: \.dayKey)
            .contains { $0.value.count > 1 }
        guard hasDuplicates else { return }

        do {
            let repository = SwiftDataTimelineRepository(modelContext: modelContext)
            _ = try repository.mergeDuplicateDayTimelines()
        } catch {
            print("Failed to merge duplicate day timelines: \(error.localizedDescription)")
        }
    }

    private func publishWidgetSnapshot() {
        guard let dayTimeline = selectedDay ?? dayTimelines.last else { return }
        TimelineWidgetSnapshotStore.save(.make(from: dayTimeline))
    }

    private func refreshSpotlightIndex() {
        let entities = dayTimelines.flatMap { day in
            day.places.map(VisitedPlaceEntity.init)
        }
        Task(priority: .utility) {
            try? await VisitedPlaceSpotlightIndexer.replaceIndex(with: entities)
        }
    }

    private func handleDeepLink(_ url: URL) {
        if url.isFileURL {
            enqueueRouteImport([url])
            return
        }

        guard url.scheme?.lowercased() == "moves" else { return }

        switch url.host?.lowercased() {
        case "today":
            openCurrentDay()
        case "tracking":
            if captureManager.isLocationTrackingAvailable {
                isShowingRouteTrackingSettings = true
            }
        case "place":
            guard let identifier = url.pathComponents.dropFirst().first,
                  let placeID = UUID(uuidString: identifier),
                  let dayIndex = dayTimelines.firstIndex(where: { day in
                      day.places.contains(where: { $0.id == placeID })
                  }) else { return }
            selectedPageIndex = dayIndex
            selectedDayKey = dayTimelines[dayIndex].dayKey
        default:
            break
        }
    }

    private func enqueueRouteImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingRouteImportURLs.append(contentsOf: urls)
        routeImportFlushTask?.cancel()
        routeImportFlushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let urls = pendingRouteImportURLs
            guard !urls.isEmpty else { return }
            droppedRouteImportConfiguration = RouteFileImportConfiguration()
            isShowingDroppedRouteImportOptions = true
        }
    }

    private func syncSelectedDayIfNeeded() {
        guard !dayTimelines.isEmpty else {
            selectedPageIndex = 0
            selectedDayKey = ""
            return
        }

        if selectedDayKey.isEmpty {
            selectedPageIndex = dayTimelines.count - 1
            selectedDayKey = dayTimelines[selectedPageIndex].dayKey
            return
        }

        if let selectedIndex = dayTimelines.firstIndex(where: { $0.dayKey == selectedDayKey }) {
            selectedPageIndex = selectedIndex
            return
        }

        if dayTimelines.indices.contains(selectedPageIndex) {
            selectedDayKey = dayTimelines[selectedPageIndex].dayKey
            return
        }

        selectedPageIndex = dayTimelines.count - 1
        selectedDayKey = dayTimelines[selectedPageIndex].dayKey
    }

    private func selectOlderDay() {
        let nextIndex = selectedPageIndex - 1
        guard dayTimelines.indices.contains(nextIndex) else { return }
        selectedPageIndex = nextIndex
    }

    private func selectNewerDay() {
        let nextIndex = selectedPageIndex + 1
        guard dayTimelines.indices.contains(nextIndex) else { return }
        selectedPageIndex = nextIndex
    }

    private func jumpToDate(_ date: Date) {
        guard !dayTimelines.isEmpty else { return }

        let calendar = Calendar.autoupdatingCurrent
        let targetStart = calendar.startOfDay(for: date)

        let closest = dayTimelines.enumerated().min { lhs, rhs in
            let lhsStart = calendar.startOfDay(for: lhs.element.dayStart)
            let rhsStart = calendar.startOfDay(for: rhs.element.dayStart)
            return abs(lhsStart.timeIntervalSince(targetStart)) < abs(rhsStart.timeIntervalSince(targetStart))
        }

        guard let closest else { return }
        selectedPageIndex = closest.offset
        selectedDayKey = closest.element.dayKey
    }

    private var datePickerSheet: some View {
        MovesJumpToDateView(
            dayTimelines: dayTimelines,
            selectedDate: selectedDay?.dayStart ?? .now,
            onSelectDate: jumpToDate,
            onDismiss: { isShowingDatePicker = false }
        )
    }

    @MainActor
    private func handleShakeToUndo() {
        let undoManager = undoController.manager
        guard undoManager.canUndo else { return }
        modelContext.undoManager = undoManager

        undoManager.undo()

        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                print("Failed to save undo changes: \(error.localizedDescription)")
            }
        }
    }
}

private struct DaySidebarRow: View {
    let day: DayTimeline

    private var totalDistance: CLLocationDistance {
        day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
    }

    private var summary: String {
        guard day.hasRecordedActivity else { return "No recorded activity" }

        var parts = [
            "\(day.uniqueLocationCount) place\(day.uniqueLocationCount == 1 ? "" : "s")",
            "\(day.moves.count) move\(day.moves.count == 1 ? "" : "s")",
        ]

        if totalDistance > 0 {
            parts.append(
                Measurement(value: totalDistance, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
            )
        }

        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(day.dayStart, format: .dateTime.weekday(.wide).day().month(.abbreviated))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer(minLength: 4)

                if day.hasImportedRouteData {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MovesPalette.routeTracking)
                        .accessibilityLabel("Contains imported data")
                }
            }

            Text(summary)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

enum TimelineExportScope {
    case allDays
    case selectedDay
}

enum TimelineExportFormat {
    case gpx
    case geoJSON
    case csv

    var contentType: UTType {
        switch self {
        case .gpx:
            return .xml
        case .geoJSON:
            return .json
        case .csv:
            return .commaSeparatedText
        }
    }

    var fileExtension: String {
        switch self {
        case .gpx:
            return "gpx"
        case .geoJSON:
            return "geojson"
        case .csv:
            return "csv"
        }
    }
}

struct TimelineExportPayload {
    let data: Data
    let filename: String
    let contentType: UTType
}

struct TimelineTrackPoint {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: Date
}

struct TimelineExportDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.xml, .json, .commaSeparatedText]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct GPXShareFile: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .xml) { file in
            let directory = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let url = directory.appending(path: file.filename)
            try file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

enum TimelineExporter {
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func makePayload(
        days: [DayTimeline],
        format: TimelineExportFormat,
        fileStem: String
    ) -> TimelineExportPayload? {
        let orderedDays = days.sorted(by: { $0.dayStart < $1.dayStart })

        let exportData: Data?
        switch format {
        case .gpx:
            exportData = gpxData(for: orderedDays)
        case .geoJSON:
            exportData = geoJSONData(for: orderedDays)
        case .csv:
            exportData = csvData(for: orderedDays)
        }

        guard let exportData else { return nil }
        return TimelineExportPayload(
            data: exportData,
            filename: "\(fileStem).\(format.fileExtension)",
            contentType: format.contentType
        )
    }

    static func makeMoveGPXPayload(
        move: MoveSegment,
        coordinates: [CLLocationCoordinate2D],
        fileStem: String
    ) -> TimelineExportPayload? {
        let points = routePoints(
            for: coordinates,
            startDate: move.timelineStartDate,
            endDate: move.endDate
        )
        guard points.count > 1 else { return nil }

        let startTitle = move.startPlace?.displayTitle ?? "Unknown start"
        let endTitle = move.endPlace?.displayTitle ?? "Unknown destination"
        let trackName = "\(startTitle) to \(endTitle)"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Moves iOS Rebuild" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(xmlEscaped(trackName))</name>
            <time>\(iso8601.string(from: move.timelineStartDate))</time>
          </metadata>
        """

        if let startPlace = move.startPlace {
            xml += """

              <wpt lat="\(coordinateString(startPlace.latitude))" lon="\(coordinateString(startPlace.longitude))">
                <name>\(xmlEscaped(startTitle))</name>
                <time>\(iso8601.string(from: move.timelineStartDate))</time>
              </wpt>
            """
        }

        if let endPlace = move.endPlace {
            xml += """

              <wpt lat="\(coordinateString(endPlace.latitude))" lon="\(coordinateString(endPlace.longitude))">
                <name>\(xmlEscaped(endTitle))</name>
                <time>\(iso8601.string(from: move.endDate))</time>
              </wpt>
            """
        }

        xml += """

          <trk>
            <name>\(xmlEscaped(trackName))</name>
            <type>\(xmlEscaped(move.transportMode.title))</type>
        """

        if let comment = move.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
           !comment.isEmpty {
            xml += """

                <desc>\(xmlEscaped(comment))</desc>
            """
        }

        xml += """

            <trkseg>
        """

        for point in points {
            xml += """

              <trkpt lat="\(coordinateString(point.latitude))" lon="\(coordinateString(point.longitude))">
                <time>\(iso8601.string(from: point.timestamp))</time>
              </trkpt>
            """
        }

        xml += """

            </trkseg>
          </trk>
        </gpx>
        """

        guard let data = xml.data(using: .utf8) else { return nil }
        return TimelineExportPayload(
            data: data,
            filename: "\(fileStem).gpx",
            contentType: .xml
        )
    }

    private static func gpxData(for days: [DayTimeline]) -> Data? {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Moves iOS Rebuild" xmlns="http://www.topografix.com/GPX/1/1">
        """

        for day in days {
            let sortedPlaces = day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
            for place in sortedPlaces {
                xml += """
                
                  <wpt lat="\(coordinateString(place.latitude))" lon="\(coordinateString(place.longitude))">
                    <name>\(xmlEscaped(place.displayTitle))</name>
                    <time>\(iso8601.string(from: place.arrivalDate))</time>
                  </wpt>
                """
            }

            let sortedMoves = day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
            guard !sortedMoves.isEmpty else { continue }

            xml += """
            
              <trk>
                <name>\(xmlEscaped(day.dayKey))</name>
            """

            for move in sortedMoves {
                let points = routePoints(for: move)
                guard points.count > 1 else { continue }

                xml += """
                
                    <trkseg>
                """

                for point in points {
                    xml += """
                    
                      <trkpt lat="\(coordinateString(point.latitude))" lon="\(coordinateString(point.longitude))">
                    """

                    if let elevation = point.elevation, elevation.isFinite {
                        xml += """
                        
                            <ele>\(elevationString(elevation))</ele>
                        """
                    }

                    xml += """
                    
                        <time>\(iso8601.string(from: point.timestamp))</time>
                      </trkpt>
                    """
                }

                xml += """
                
                    </trkseg>
                """
            }

            xml += """
            
              </trk>
            """
        }

        xml += """
        
        </gpx>
        """

        return xml.data(using: .utf8)
    }

    private static func geoJSONData(for days: [DayTimeline]) -> Data? {
        var features: [[String: Any]] = []

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) {
                var properties: [String: Any] = [
                    "record_type": "place",
                    "title": place.displayTitle,
                    "arrival_time": iso8601.string(from: place.arrivalDate),
                    "day_key": day.dayKey,
                ]

                if let departureDate = place.departureDate {
                    properties["departure_time"] = iso8601.string(from: departureDate)
                }
                if let userLabel = place.userLabel, !userLabel.isEmpty {
                    properties["user_label"] = userLabel
                }
                if let autoLabel = place.autoLabel, !autoLabel.isEmpty {
                    properties["auto_label"] = autoLabel
                }
                if let comment = place.comment, !comment.isEmpty {
                    properties["comment"] = comment
                }

                let geometry: [String: Any] = [
                    "type": "Point",
                    "coordinates": [place.longitude, place.latitude],
                ]

                features.append([
                    "type": "Feature",
                    "geometry": geometry,
                    "properties": properties,
                ])
            }

            for move in day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate }) {
                let points = routePoints(for: move)
                let coordinates = points.map { [$0.longitude, $0.latitude] }
                guard coordinates.count > 1 else { continue }

                var properties: [String: Any] = [
                    "record_type": "move",
                    "day_key": day.dayKey,
                    "transport_mode": move.transportMode.rawValue,
                    "start_time": iso8601.string(from: move.timelineStartDate),
                    "end_time": iso8601.string(from: move.endDate),
                    "distance_meters": move.distanceMeters,
                    "start_place": move.startPlace?.displayTitle ?? "Unknown start",
                    "end_place": move.endPlace?.displayTitle ?? "Unknown destination",
                ]

                if let stepCount = move.stepCount {
                    properties["step_count"] = stepCount
                }
                if let comment = move.comment, !comment.isEmpty {
                    properties["comment"] = comment
                }

                let geometry: [String: Any] = [
                    "type": "LineString",
                    "coordinates": coordinates,
                ]

                features.append([
                    "type": "Feature",
                    "geometry": geometry,
                    "properties": properties,
                ])
            }
        }

        let collection: [String: Any] = [
            "type": "FeatureCollection",
            "features": features,
        ]

        return try? JSONSerialization.data(
            withJSONObject: collection,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func csvData(for days: [DayTimeline]) -> Data? {
        var rows: [String] = []
        rows.append("record_type,start_time,end_time,title,day_key,transport_mode,distance_meters,step_count,latitude,longitude,comment")

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) {
                rows.append(
                    [
                        "place",
                        iso8601.string(from: place.arrivalDate),
                        place.departureDate.map(iso8601.string(from:)) ?? "",
                        csvEscaped(place.displayTitle),
                        day.dayKey,
                        "",
                        "",
                        "",
                        coordinateString(place.latitude),
                        coordinateString(place.longitude),
                        csvEscaped(place.comment ?? ""),
                    ].joined(separator: ",")
                )
            }

            for move in day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate }) {
                let title = "\(move.startPlace?.displayTitle ?? "Unknown start") to \(move.endPlace?.displayTitle ?? "Unknown destination")"
                rows.append(
                    [
                        "move",
                        iso8601.string(from: move.timelineStartDate),
                        iso8601.string(from: move.endDate),
                        csvEscaped(title),
                        day.dayKey,
                        move.transportMode.rawValue,
                        String(format: "%.2f", move.distanceMeters),
                        move.stepCount.map(String.init) ?? "",
                        "",
                        "",
                        csvEscaped(move.comment ?? ""),
                    ].joined(separator: ",")
                )
            }
        }

        return rows.joined(separator: "\n").data(using: .utf8)
    }

    private static func routePoints(for move: MoveSegment) -> [TimelineTrackPoint] {
        var points: [TimelineTrackPoint] = []
        points.reserveCapacity(move.samples.count + 2)

        if let startPlace = move.startPlace {
            points.append(
                TimelineTrackPoint(
                    latitude: startPlace.latitude,
                    longitude: startPlace.longitude,
                    elevation: nil,
                    timestamp: move.timelineStartDate
                )
            )
        }

        let sortedSamples = move.samples
            .preferredRouteDisplaySamples
            .sorted(by: { $0.timestamp < $1.timestamp })
        for sample in sortedSamples {
            points.append(
                TimelineTrackPoint(
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    elevation: sample.altitude,
                    timestamp: sample.timestamp
                )
            )
        }

        if let endPlace = move.endPlace {
            points.append(
                TimelineTrackPoint(
                    latitude: endPlace.latitude,
                    longitude: endPlace.longitude,
                    elevation: nil,
                    timestamp: move.endDate
                )
            )
        }

        let sortedPoints = points.sorted(by: { $0.timestamp < $1.timestamp })
        return dedupeSequentialPoints(in: sortedPoints)
    }

    private static func routePoints(
        for coordinates: [CLLocationCoordinate2D],
        startDate: Date,
        endDate: Date
    ) -> [TimelineTrackPoint] {
        let coordinates = RouteCoordinateOps.dedupeSequentialCoordinates(
            coordinates,
            minimumDistanceMeters: 0.01
        )
        guard coordinates.count > 1 else { return [] }

        let segmentDistances = zip(coordinates, coordinates.dropFirst()).map {
            RouteCoordinateOps.distanceMeters(from: $0.0, to: $0.1)
        }
        let totalDistance = segmentDistances.reduce(0, +)
        let duration = max(endDate.timeIntervalSince(startDate), 0)
        var distanceTravelled: CLLocationDistance = 0

        return coordinates.enumerated().map { index, coordinate in
            if index > 0 {
                distanceTravelled += segmentDistances[index - 1]
            }

            let fraction: Double
            if totalDistance > 0 {
                fraction = distanceTravelled / totalDistance
            } else {
                fraction = Double(index) / Double(coordinates.count - 1)
            }

            return TimelineTrackPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                elevation: nil,
                timestamp: startDate.addingTimeInterval(duration * fraction)
            )
        }
    }

    private static func dedupeSequentialPoints(in points: [TimelineTrackPoint]) -> [TimelineTrackPoint] {
        guard !points.isEmpty else { return [] }

        var deduped: [TimelineTrackPoint] = []
        deduped.reserveCapacity(points.count)

        var previousKey: String?
        for point in points {
            let key = "\(Int(point.timestamp.timeIntervalSince1970.rounded()))|\(coordinateString(point.latitude))|\(coordinateString(point.longitude))"
            if key == previousKey { continue }
            deduped.append(point)
            previousKey = key
        }

        return deduped
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func csvEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func coordinateString(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func elevationString(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct PanelSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MovesPalette.card.opacity(colorScheme == .dark ? 0.88 : 0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(MovesPalette.border, lineWidth: 1)
                    }
            }
    }
}

struct FrostedCircleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(enabled ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.55))
            .background {
                Circle()
                    .fill(
                        MovesPalette.frostedFill.opacity(
                            enabled
                                ? (colorScheme == .dark ? 0.95 : 1.0)
                                : (colorScheme == .dark ? 0.55 : 0.75)
                        )
                    )
                    .overlay {
                        Circle()
                            .stroke(MovesPalette.border.opacity(enabled ? 0.9 : 0.7), lineWidth: 1)
                    }
                    .glassEffect(.regular, in: Circle())
            }
    }
}

private struct RouteTrackingToolbarButton: View {
    let endsAt: Date?
    let authorizationStatus: CLAuthorizationStatus
    let tapAction: () -> Void
    let longPressAction: () -> Void

    @State private var isPulsing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remainingSeconds = endsAt.map { $0.timeIntervalSince(context.date) } ?? 0
            let isRunning = remainingSeconds > 0 && isAuthorizedForRealTracking

            HStack(spacing: 5) {
                Image(systemName: "location.fill.viewfinder")
                    .foregroundStyle(isRunning ? .red : Color.primary)
                    .scaleEffect(isRunning && isPulsing ? 1.16 : 1)
                    .opacity(isRunning && isPulsing ? 0.55 : 1)

                if isRunning {
                    Text(routeTrackingCountdownText(for: remainingSeconds))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                isRunning
                    ? "Real route tracking, \(routeTrackingCountdownText(for: remainingSeconds)) remaining"
                    : "Real route tracking"
            )
            .accessibilityHint("Tap to open settings. Touch and hold to start tracking.")
            .accessibilityAddTraits(.isButton)
            .onTapGesture(perform: tapAction)
            .onLongPressGesture(minimumDuration: 0.55, perform: longPressAction)
            .onAppear {
                isPulsing = isRunning
            }
            .onChange(of: isRunning) { _, newValue in
                isPulsing = newValue
            }
            .animation(
                isRunning
                    ? .easeInOut(duration: 1.45).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .help("Real route tracking")
        }
    }

    private var isAuthorizedForRealTracking: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    private func routeTrackingCountdownText(for remainingSeconds: TimeInterval) -> String {
        if remainingSeconds < 60 {
            return "\(max(Int(ceil(remainingSeconds)), 0))s"
        }

        return DurationFormatter.text(for: remainingSeconds)
    }
}

extension View {
    func panelSurface() -> some View {
        modifier(PanelSurfaceModifier())
    }

    func frostedCircle(enabled: Bool) -> some View {
        modifier(FrostedCircleModifier(enabled: enabled))
    }
}

private struct ShakeToUndoDetector: UIViewRepresentable {
    let undoManager: UndoManager
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeToUndoView {
        let view = ShakeToUndoView()
        view.managedUndoManager = undoManager
        view.onShake = onShake
        return view
    }

    func updateUIView(_ uiView: ShakeToUndoView, context: Context) {
        uiView.managedUndoManager = undoManager
        uiView.onShake = onShake
    }
}

private final class ShakeToUndoView: UIView {
    var managedUndoManager: UndoManager?
    var onShake: (() -> Void)?
    private var activeObserver: NSObjectProtocol?

    override var undoManager: UndoManager? {
        managedUndoManager
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.becomeFirstResponderIfPossible()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponderIfPossible()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        becomeFirstResponderIfPossible()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else {
            super.motionEnded(motion, with: event)
            return
        }

        onShake?()
    }

    private func becomeFirstResponderIfPossible() {
        guard window != nil else { return }
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }
}

private extension ProcessInfo {
    var isRunningForPreviews: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try! ModelContainer(
            for: DayTimeline.self,
            VisitPlace.self,
            KnownLocation.self,
            MoveSegment.self,
            LocationSample.self,
            MovesDeviceProfile.self,
            configurations: configuration
        )

        ContentView()
            .modelContainer(container)
            .environmentObject(MovesLocationCaptureManager(modelContainer: container))
            .environmentObject(AppUndoController())
            .environmentObject(MovesCloudDataPresencePublisher(modelContainer: container))
            .environmentObject(MultiDevicePresenceManager(modelContainer: container))
    }
}
