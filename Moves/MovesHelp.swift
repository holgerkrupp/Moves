import Foundation
import ESADesignKit
import SwiftUI

/// Shared, offline help content used by the iOS Documentation hub and macOS Moves Help.
/// Keep feature claims and navigation labels in sync with the user guide inventory.
enum MovesHelpTopic: String, CaseIterable, Identifiable, Hashable {
    case startHere
    case timeline
    case tracking
    case places
    case routes
    case searchAndStatistics
    case importing
    case exportAndBackup
    case sync
    case integrationsAndPrivacy
    case widgetsAndWatch
    case troubleshooting

    var id: String { rawValue }

    var title: String {
        let key: String = switch self {
        case .startHere: "Start Here"
        case .timeline: "Your Timeline"
        case .tracking: "Tracking & Battery"
        case .places: "Places & Regular Places"
        case .routes: "Routes & Move Mapping"
        case .searchAndStatistics: "Search, Statistics & Connections"
        case .importing: "Importing Data"
        case .exportAndBackup: "Export, Backup & Sharing"
        case .sync: "iCloud Sync & Multiple Devices"
        case .integrationsAndPrivacy: "Integrations & Privacy"
        case .widgetsAndWatch: "Widgets, Shortcuts & Apple Watch"
        case .troubleshooting: "Troubleshooting & FAQ"
        }
        return localizedHelp(key)
    }

    var subtitle: String {
        let key: String = switch self {
        case .startHere: "A quick introduction to your location timeline."
        case .timeline: "Browse days, understand records, and make changes."
        case .tracking: "Choose how Moves records places and detailed routes."
        case .places: "Label visits and recognize places you return to."
        case .routes: "Understand route display, matching, and transport colors."
        case .searchAndStatistics: "Find visits and understand travel connections."
        case .importing: "Bring route files and supported workout routes into Moves."
        case .exportAndBackup: "Share selected data or keep a separate backup."
        case .sync: "Understand private iCloud sync and device roles."
        case .integrationsAndPrivacy: "Control external uploads and protect location data."
        case .widgetsAndWatch: "Use supported shortcuts, widgets, and Watch features."
        case .troubleshooting: "Common causes and safe recovery steps."
        }
        return localizedHelp(key)
    }

    var systemImage: String {
        switch self {
        case .startHere: "hand.wave"
        case .timeline: "calendar.day.timeline.left"
        case .tracking: "location.circle"
        case .places: "mappin.and.ellipse"
        case .routes: "point.topleft.down.curvedto.point.bottomright.up"
        case .searchAndStatistics: "chart.xyaxis.line"
        case .importing: "square.and.arrow.down"
        case .exportAndBackup: "square.and.arrow.up"
        case .sync: "icloud"
        case .integrationsAndPrivacy: "lock.shield"
        case .widgetsAndWatch: "applewatch"
        case .troubleshooting: "questionmark.circle"
        }
    }

    var searchTerms: String {
        let content = sections.flatMap { [$0.title] + $0.paragraphs + $0.bullets }
        let mapping = includesMoveMapping
            ? TransportMode.allCases.map { "\($0.title) \(MovesHelpMappingRule.text(for: $0))" }
            : []
        return ([title, subtitle] + content + mapping).joined(separator: " ")
    }

    var includesMoveMapping: Bool { self == .routes }

    var sections: [MovesHelpSection] {
        switch self {
        case .startHere:
            [
                .init("What Moves records", paragraphs: [
                    "Moves builds a timeline from recorded visits and the movement between them. Your history appears by day, with a map and details for each place and move.",
                    "Location tracking happens on iPhone. The Mac app is for browsing, managing, importing, and exporting timeline data; it does not record your location."
                ]),
                .init("First steps", bullets: [
                    "On iPhone, allow the location access requested by Moves if you want background visit recording. Keep Background App Refresh and Location Services available to iOS.",
                    "Open the timeline and select a day to inspect its places and moves. New or sparse location observations may take time to appear.",
                    "Open Settings to configure Regular Places, tracking, integrations, import, and export. iCloud sync is separate from location recording."
                ]),
                .init("What to expect", paragraphs: [
                    "Moves uses system location services. iOS can delay or omit background observations, so a timeline may have gaps or estimated movement. Precise route tracking is available for a limited active session and uses more battery."
                ])
            ]
        case .timeline:
            [
                .init("Browse a day", bullets: [
                    "Use the date control to move to another day; the timeline shows visits and move segments in time order.",
                    "Select a visit or move to inspect its details. Depending on the record, you can edit its label, transport mode, comments, or route details.",
                    "Use Search or Statistics to find a place or connection, then open the relevant day to inspect the records."
                ]),
                .init("Visits and moves", paragraphs: [
                    "A visit represents time associated with a place. A move represents travel between places. Sparse system observations are not exact departure or arrival times, so inferred move timing can be approximate.",
                    "Appearance settings can show raw operating-system location fixes or reconstructed routes. Raw fixes are observations and are not joined into a recorded route."
                ]),
                .init("Correcting a timeline", bullets: [
                    "Edit the affected record when you know its correct label or transport mode.",
                    "Fill missing moves from the timeline when the available visit data supports an estimate.",
                    "Deleted records can generally be restored immediately with Undo where that action is offered. Data Maintenance includes deduplication with an undo snapshot."
                ])
            ]
        case .tracking:
            [
                .init("Background place recording", paragraphs: [
                    "Moves listens for the location changes provided by iOS, including significant-location changes and visits. This is designed for lower energy use than continuous GPS, but observations can be sparse or delayed.",
                    "Allow the location permissions requested by iOS and keep Location Services enabled. iOS controls when background updates are delivered; Moves cannot guarantee a point at every moment."
                ]),
                .init("Real Route Tracking", bullets: [
                    "Start a route-tracking session from the Tracking controls when you need a detailed path for a trip.",
                    "The session records more frequent GPS locations and uses more battery. It is time-limited; use the status shown in Moves, Live Activity, or Watch when available to check whether it is active.",
                    "Stop tracking when the trip ends. The saved route retains its recorded GPS geometry."
                ]),
                .init("Gaps and estimates", paragraphs: [
                    "Moves can estimate a move between consecutive visits when automatic gap filling is enabled. An estimated route or transport mode is not the same as a continuous GPS recording."
                ])
            ]
        case .places:
            [
                .init("Visit labels", paragraphs: [
                    "A visit can have a label for that occurrence. A Regular Place is a saved named area, such as Home or Work, that can match visits within its radius."
                ]),
                .init("Manage Regular Places", bullets: [
                    "Open Settings → Regular Places to review, add, edit, or remove saved places.",
                    "You can also create or edit a Regular Place from a visit’s place details where that action is available.",
                    "The radius controls how close a visit must be to match. Nearby or overlapping saved areas can make a match ambiguous; review the visit label after changing definitions."
                ]),
                .init("Other visits here", paragraphs: [
                    "The place detail screen can show other visits associated with the same place, helping you compare dates and correct labels. Changing a saved place definition may affect how visits are recognized."
                ])
            ]
        case .routes:
            [
                .init("Route sources", paragraphs: [
                    "A route on the map can come from recorded GPS, an imported track, or a route inferred from map directions. Map matching changes display geometry; it does not turn inferred connector points into recorded location samples.",
                    "Manual choices, imported declared modes, Health workout modes, and detailed recorded tracks are retained. A flight connector between endpoints is inferred display geometry, not recorded GPS."
                ]),
                .init("Move Mapping", paragraphs: [
                    "The transport mode controls whether Moves asks MapKit for matching directions and which route color appears. The mode rules and map colors below are generated from the app’s transport modes and palette.",
                    "A route that cannot be matched keeps its recorded coordinates when available. Network or routing failures do not prove that no terrestrial route exists."
                ]),
                .init("Imported routes", paragraphs: [
                    "Import mapping choices apply to incoming route files: automatic mode inference, one selected transport mode, or raw GPS data. This is separate from matching an inferred move on a map.",
                    "Use Appearance settings to choose raw operating-system fixes or reconstructed route display."
                ])
            ]
        case .searchAndStatistics:
            [
                .init("Search visits", paragraphs: [
                    "Search visits by place name, note, or date using the Search screen. Open a result to see its day and surrounding timeline context."
                ]),
                .init("Statistics and connections", paragraphs: [
                    "Statistics summarize the visits and moves currently in your timeline. Connections describe travel between places; direct connections and connections with intermediate stops are different results.",
                    "Missing observations, incomplete history, and estimated moves can affect totals and connection counts. Treat statistics as a summary of recorded data, not a complete account of every trip."
                ]),
                .init("Share a result", paragraphs: [
                    "Use Create & Share to choose a supported map or statistics design and time span. Review the selected period before sharing because location and place names can be sensitive."
                ])
            ]
        case .importing:
            [
                .init("Route files", paragraphs: [
                    "Moves supports GPX, TCX, KML, GeoJSON, and JSON route data. The file picker and share sheet show which files the current platform can open."
                ]),
                .init("Choose import options", bullets: [
                    "Automatic mapping infers a mode from route metadata and geometry; a dedicated mode applies your selection; Raw keeps the original points without route matching.",
                    "When times overlap existing data, choose whether to keep existing data, skip dates that already have data, expand around existing ranges, or overwrite overlapping ranges.",
                    "Review the import queue to monitor progress and pause, resume, retry, or inspect failed work where available. Already committed files remain when a later file fails."
                ]),
                .init("Other route sources", paragraphs: [
                    "Health workout route import and automatic watch-folder imports are available on supported devices and configurations. Follow the permission and folder controls shown in Settings → Import."
                ])
            ]
        case .exportAndBackup:
            [
                .init("Export timeline data", bullets: [
                    "From Export & Backup, export the selected day or all history in a supported format such as GPX, GeoJSON, or CSV.",
                    "Individual places and moves may also offer export or sharing actions in their detail or context menus.",
                    "Available fields vary by format. Exported files can contain precise location and time data; choose a private destination and share them deliberately."
                ]),
                .init("Backup is separate from sync", paragraphs: [
                    "A manual export or scheduled iCloud Drive backup is a separate file copy. iCloud sync keeps app data available across devices and does not create an independently browsable backup file.",
                    "Settings → Export & Backup controls the daily backup option, format, and folder organization. Verify that a backup file was created before relying on it."
                ]),
                .init("Sharing", paragraphs: [
                    "Shared maps and statistics can include routes, dates, or place labels depending on the selected design. Check the preview and time span before sending or publishing."
                ])
            ]
        case .sync:
            [
                .init("Private iCloud data", paragraphs: [
                    "Moves stores timeline data locally and can synchronize it through your private iCloud container when iCloud is available and enabled. Sync is asynchronous; updates may take time to reach another device.",
                    "The Mac app is for browsing and managing synchronized data. Use the iPhone as the device that records location. Sync does not guarantee that iOS will deliver background location updates."
                ]),
                .init("Sync status and diagnostics", paragraphs: [
                    "Settings → Status shows recent successful imports and exports for this device. A system deferral means pending changes may still be waiting to upload; a later successful export clears the active warning while the event remains in the local diagnostic history.",
                    "Refresh Diagnostics updates the local snapshot and event view. CloudKit schedules synchronization automatically, so this action does not force an upload. Copy Diagnostics provides local counts, timestamps, stable record IDs, and privacy-safe error details for troubleshooting."
                ]),
                .init("Check sync status", bullets: [
                    "Open the Status card or Settings → Tracking to review sync and diagnostics information.",
                    "Keep the devices signed in to the expected Apple Account and connected to iCloud. Allow time for queued changes to upload and download.",
                    "Choose one device for location recording to avoid confusing gaps; other devices can browse the shared timeline."
                ]),
                .init("What sync does not do", paragraphs: [
                    "A local export, backup file, or upload to an external location service is a separate action. Do not assume these copies are synchronized or automatically refreshed."
                ])
            ]
        case .integrationsAndPrivacy:
            [
                .init("External location services", paragraphs: [
                    "Moves can upload location data to configured services including Dawarich, Reitti, GeoPulse, OwnTracks Recorder, and Traccar. Availability and setup vary by service. Open Settings → Integrations to see current options and enable each destination.",
                    "An integration sends data outside Moves and your private iCloud container. Review the destination, server address, and credentials before enabling uploads. Existing history may require a separate upload action."
                ]),
                .init("Credentials and permissions", paragraphs: [
                    "Integration credentials are stored for use by the app and are not part of a shared help page or export. Grant location, Health, or file access only for the features you choose to use.",
                    "Imported files and exported files are handled by the file destination you select. Removing an integration does not delete data already sent to that service."
                ]),
                .init("Before sharing", paragraphs: [
                    "Location history can reveal home, work, routines, and travel. Check dates, map coverage, place names, and recipient permissions before sharing an export or image."
                ])
            ]
        case .widgetsAndWatch:
            [
                .init("Widgets and Shortcuts", paragraphs: [
                    "Moves provides supported widgets and App Intents on compatible Apple platforms. Add a widget from the system widget gallery or find Moves actions in Shortcuts; the actions offered depend on the device and installed app version.",
                    "Available actions can include tracking controls, status, timeline summaries, and export. Check the Shortcuts action description before running an action that changes tracking or creates a file."
                ]),
                .init("Apple Watch", paragraphs: [
                    "The Watch app and complications provide supported recording and status controls when installed and paired. iPhone and Watch behavior can differ; use the status shown on the device that is recording to confirm a session."
                ]),
                .init("Platform availability", paragraphs: [
                    "iPhone handles location recording. Mac provides timeline browsing, route-file import, and data export. Widgets, Live Activity, and Watch controls appear only on supported devices and OS versions."
                ])
            ]
        case .troubleshooting:
            [
                .init("A visit or move is missing", bullets: [
                    "Check Location Services and the permissions granted to Moves. iOS may delay or omit background observations, especially after force-quitting or restricting background activity.",
                    "Review nearby days and the raw-fix display in Appearance to see whether observations exist without a reconstructed route.",
                    "If two visits have no move between them, check whether automatic gap filling is enabled. Estimates may still be incomplete."
                ]),
                .init("A route looks straight or the mode is wrong", bullets: [
                    "A straight connector can be inferred display geometry, particularly for flights or when detailed route points are unavailable.",
                    "Check the move’s transport mode and recorded-route details. Manual and imported metadata can take priority over inferred matching.",
                    "Map directions depend on network availability and returned routing data. A temporary routing failure can leave recorded geometry in place."
                ]),
                .init("Import, sync, or battery issue", bullets: [
                    "For imports, open the queue and retry a failed item after checking the file and selected import options.",
                    "For sync delays, check Settings → Status for recent import/export times and refresh diagnostics after allowing iCloud time to process changes. Avoid deleting data to resolve a temporary delay.",
                    "Detailed GPS route tracking uses more battery than background place recording. Stop an active route session when it is no longer needed."
                ]),
                .init("Safe maintenance", paragraphs: [
                    "Use Data Maintenance only after reviewing its description. Historical deduplication creates an undo snapshot; keep that snapshot available until you have confirmed the timeline."
                ])
            ]
        }
    }
}

struct MovesHelpSection: Identifiable {
    let title: String
    let paragraphs: [String]
    let bullets: [String]
    var id: String { title }

    init(_ title: String, paragraphs: [String] = [], bullets: [String] = []) {
        self.title = localizedHelp(title)
        self.paragraphs = paragraphs.map(localizedHelp)
        self.bullets = bullets.map(localizedHelp)
    }
}

struct MovesHelpIndexView: View {
    @State private var searchText = ""

    private var topics: [MovesHelpTopic] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MovesHelpTopic.allCases }
        return MovesHelpTopic.allCases.filter { $0.searchTerms.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            ForEach(topics) { topic in
                NavigationLink {
                    MovesHelpTopicView(topic: topic)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(topic.title).font(.headline).accessibilityAddTraits(.isHeader)
                            Text(topic.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    } icon: {
                        Image(systemName: topic.systemImage)
                            .foregroundStyle(MovesPalette.transport(topic == .routes ? .train : .unknown))
                    }
                }
                .accessibilityHint(topic.subtitle)
            }
        }
 #if os(iOS)
        .listStyle(.insetGrouped)
 #else
        .listStyle(.sidebar)
 #endif
        .searchable(text: $searchText, prompt: "Search documentation")
        .navigationTitle("Documentation")
 #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
 #endif
    }
}

struct MovesHelpTopicView: View {
    let topic: MovesHelpTopic

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(topic.sections) { section in
                    MovesHelpCard(title: section.title) {
                        ForEach(section.paragraphs, id: \.self) { paragraph in
                            Text(localizedHelp(paragraph)).helpBodyText()
                        }
                        if !section.bullets.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(Array(section.bullets.enumerated()), id: \.offset) { index, bullet in
                                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                                        Text("\(index + 1).")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(localizedHelp(bullet)).helpBodyText()
                                    }
                                }
                            }
                        }
                    }
                }
                if topic.includesMoveMapping { MovesHelpMappingGuideView() }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background(.background)
        .navigationTitle(topic.title)
 #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
 #endif
    }
}

struct MovesHelpMappingGuideView: View {
    private var modes: [TransportMode] { TransportMode.allCases }

    var body: some View {
        MovesHelpCard(title: localizedHelp("Move Mapping by transport mode")) {
            Text(localizedHelp("Moves chooses whether and how a recorded route is matched to map directions based on the selected transport mode."))
                .helpBodyText()
            ForEach(modes, id: \.rawValue) { mode in
                VStack(alignment: .leading, spacing: 8) {
                    Label(mode.title, systemImage: mode.symbolName)
                        .font(.subheadline.weight(.semibold))
                    Text(MovesHelpMappingRule.text(for: mode)).helpBodyText()
                    HStack(spacing: 12) {
                        mappingColor(localizedHelp("Move detail"), color: MovesPalette.moveDetailRoute(for: mode))
                        mappingColor(localizedHelp("History map"), color: MovesPalette.historyMapRoute(for: mode))
                    }
                }
                .padding(.vertical, 5)
                Divider()
            }
            Text(localizedHelp("Manual routes and imported route geometry are preserved. Real route tracking and Health workout tracks keep their recorded GPS. Health routes use pink in move details; route tracking and imported detailed tracks use the route-tracking color."))
                .helpBodyText()
            HStack(spacing: 12) {
                mappingColor(localizedHelp("Health workout"), color: MovesPalette.healthRoute)
                mappingColor(localizedHelp("Route tracking / import"), color: MovesPalette.routeTracking)
            }
            Text(localizedHelp("Flight connectors are inferred display geometry between endpoints. They are not saved as recorded GPS points. On the history map, stationary, walking, running, cycling, automotive, motorcycle, and unknown moves use the general Moves color; swimming, train, plane, and boat keep their mode colors."))
                .helpBodyText()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func mappingColor(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum MovesHelpMappingRule {
    static func text(for mode: TransportMode) -> String {
        let key: String = switch mode {
        case .stationary: "No network matching; recorded coordinates are shown when available."
        case .walking, .running: "Try MapKit walking directions. If no candidate fits the recorded samples, keep the recorded route."
        case .swimming: "No network matching; keep the recorded GPS route."
        case .cycling: "Try cycling directions, then walking directions where cycling routing is unavailable. Keep the recorded route if neither candidate fits."
        case .automotive, .motorcycle: "Try driving directions, with walking directions as a fallback near endpoints that roads cannot reach. Keep the recorded route if no candidate fits."
        case .train: "Try public-transit directions only; driving routes are rejected. If no suitable transit geometry is returned, keep the recorded fixes. Transit data does not guarantee a rail-only line."
        case .plane: "Use an inferred curved connector between endpoints when no detailed recorded route is available. The connector is display geometry, not recorded GPS."
        case .boat: "No road or transit matching; keep the recorded route."
        case .unknown: "No network matching; recorded coordinates are shown when available."
        }
        return localizedHelp(key)
    }
}

private struct MovesHelpCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizedHelp(title)).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary, lineWidth: 1))
    }
}

private extension View {
    func helpBodyText() -> some View {
        self.font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func localizedHelp(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), comment: "Moves in-app help")
}
