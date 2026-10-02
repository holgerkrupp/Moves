import Foundation
import CoreLocation
import WatchConnectivity
import MapKit

private struct WatchRoutePayload: Codable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let sourceRawValue: String
    let samples: [WatchLocationSamplePayload]
}

private struct WatchRoutePoint: Codable, Sendable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct WatchRouteSnapshot: Sendable {
    let points: [WatchRoutePoint]
}

/// Owns all Watch route filesystem and JSON work. WatchLocationTracker is a
/// MainActor object because it publishes SwiftUI state, but route persistence
/// and backlog inspection must never run on that actor.
private actor WatchRouteStore {
    private static let manifestFilename = "manifest.json"
    private static let maxPresentationPoints = 1_200

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var queuedFiles: [URL]?
    private var todayDayKey: String?
    private var todayPoints: [WatchRoutePoint] = []

    init(directory: URL) {
        self.directory = directory
    }

    func persist(_ payload: WatchRoutePayload) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let dayKey = Self.dayKey(for: payload.startedAt)
        let filename = "\(dayKey)-\(payload.id.uuidString).json"
        let fileURL = directory.appendingPathComponent(filename)
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: .atomic)

        queuedFiles = nil
        if todayDayKey == dayKey {
            todayPoints.append(contentsOf: payload.samples.map {
                WatchRoutePoint(latitude: $0.latitude, longitude: $0.longitude)
            })
            todayPoints = Self.downsample(todayPoints, maximumCount: Self.maxPresentationPoints)
        }
    }

    func todaySnapshot(for date: Date) throws -> WatchRouteSnapshot {
        let dayKey = Self.dayKey(for: date)
        if todayDayKey != dayKey {
            todayDayKey = dayKey
            todayPoints = try loadTodayPoints(dayKey: dayKey)
        }
        return WatchRouteSnapshot(points: todayPoints)
    }

    func nextTransferFile() throws -> URL? {
        if queuedFiles == nil {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            queuedFiles = files
                .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != Self.manifestFilename }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return queuedFiles?.first
    }

    func markTransferred(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        queuedFiles?.removeAll { $0 == url }
    }

    private func loadTodayPoints(dayKey: String) throws -> [WatchRoutePoint] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var points: [WatchRoutePoint] = []
        for fileURL in files where fileURL.pathExtension.lowercased() == "json" {
            try Task.checkCancellation()
            let name = fileURL.deletingPathExtension().lastPathComponent
            // New files carry their day in the filename, so normal launches
            // do not need to open old route payloads merely to classify them.
            guard name.hasPrefix("\(dayKey)-") else { continue }
            let data = try Data(contentsOf: fileURL)
            let payload = try decoder.decode(WatchRoutePayload.self, from: data)
            points.append(contentsOf: payload.samples.map {
                WatchRoutePoint(latitude: $0.latitude, longitude: $0.longitude)
            })
        }
        return Self.downsample(points, maximumCount: Self.maxPresentationPoints)
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func downsample(_ points: [WatchRoutePoint], maximumCount: Int) -> [WatchRoutePoint] {
        guard points.count > maximumCount, maximumCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { points[Int((Double($0) * step).rounded())] }
    }
}

private struct WatchLocationSamplePayload: Codable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let speed: Double

    init(location: CLLocation) {
        timestamp = location.timestamp
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        horizontalAccuracy = location.horizontalAccuracy
        speed = location.speed
    }
}

private struct WatchTimelineWidgetSnapshot: Codable {
    let dayTitle: String
    let totalDistanceMeters: Double
    let visitedLocationCount: Int
    let moveCount: Int
    let routePoints: [WatchTimelineRoutePoint]?
}

private struct WatchTimelineRoutePoint: Codable {
    let latitude: Double
    let longitude: Double
}

struct WatchDaySummary {
    let dayTitle: String
    let totalDistanceMeters: Double
    let visitedLocationCount: Int
    let moveCount: Int

    static let placeholder = WatchDaySummary(
        dayTitle: Date.now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
        totalDistanceMeters: 0,
        visitedLocationCount: 0,
        moveCount: 0
    )
}

private enum WatchWidgetSharedStore {
    static let appGroupIdentifier = "group.de.holgerkrupp.Moves"
    static let snapshotKey = "Moves.widgetSnapshot.v1"

    static var userDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}

@MainActor
final class WatchLocationTracker: NSObject, ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var lastHorizontalAccuracy: CLLocationAccuracy?
    @Published private(set) var statusText = "Ready"
    @Published private(set) var daySummary = WatchDaySummary.placeholder
    @Published private(set) var todayRouteCoordinates: [CLLocationCoordinate2D] = []

    private let manager = CLLocationManager()
    private let routeStore: WatchRouteStore
    private var activeSamples: [CLLocation] = []
    private var activeStartedAt: Date?
    private var syncedRouteCoordinates: [CLLocationCoordinate2D] = []
    private var routeTransferInProgress = false

    override init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        routeStore = WatchRouteStore(directory: base.appendingPathComponent("WatchRoutes", isDirectory: true))
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 8
        activateConnectivity()
    }

    func toggleTracking() {
        isTracking ? stopHighAccuracyTracking() : startHighAccuracyTracking()
    }

    func startFallbackMonitoring() {
        requestAuthorizationIfNeeded()
        guard !isTracking else { return }

        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 200
        manager.startUpdatingLocation()
        statusText = "Lower-power changes"
        refreshDaySummary()
        loadTodayRouteSnapshot()
    }

    func flushStoredRoutes() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, !routeTransferInProgress else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let fileURL = try? await routeStore.nextTransferFile() else { return }
            await MainActor.run {
                guard !self.routeTransferInProgress else { return }
                self.routeTransferInProgress = true
                session.transferFile(fileURL, metadata: nil)
            }
        }
    }

    private func startHighAccuracyTracking() {
        requestAuthorizationIfNeeded()
        activeStartedAt = .now
        activeSamples.removeAll()
        sampleCount = 0
        isTracking = true
        statusText = "High accuracy GPS"
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 8
        manager.startUpdatingLocation()
        loadTodayRouteSnapshot()
    }

    private func stopHighAccuracyTracking() {
        manager.stopUpdatingLocation()
        isTracking = false
        statusText = "Lower-power changes"
        persistActiveRoute(sourceRawValue: "watchRouteTracking")
        activeStartedAt = nil
        activeSamples.removeAll()
        startFallbackMonitoring()
    }

    private func requestAuthorizationIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .denied, .restricted:
            statusText = "Location denied"
        @unknown default:
            break
        }
    }

    private func appendLocations(_ locations: [CLLocation], sourceRawValue: String) {
        let usableLocations = locations.filter { location in
            location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 200
        }
        guard !usableLocations.isEmpty else { return }

        if isTracking {
            activeSamples.append(contentsOf: usableLocations)
            sampleCount = activeSamples.count
        } else {
            activeSamples = usableLocations
            activeStartedAt = usableLocations.first?.timestamp
            sampleCount = usableLocations.count
            persistActiveRoute(sourceRawValue: sourceRawValue)
            activeSamples.removeAll()
            activeStartedAt = nil
        }

        lastHorizontalAccuracy = usableLocations.last?.horizontalAccuracy
        appendToTodayRouteCache(usableLocations.map { WatchRoutePoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
    }

    private func persistActiveRoute(sourceRawValue: String) {
        guard let first = activeSamples.first,
              let last = activeSamples.last else {
            return
        }

        let payload = WatchRoutePayload(
            id: UUID(),
            startedAt: activeStartedAt ?? first.timestamp,
            endedAt: last.timestamp,
            sourceRawValue: sourceRawValue,
            samples: activeSamples.map(WatchLocationSamplePayload.init)
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                try await routeStore.persist(payload)
                await MainActor.run {
                    self.flushStoredRoutes()
                }
            } catch is CancellationError {
                // The payload remains in memory and will be retried by the next event.
            } catch {
                await MainActor.run { self.statusText = "Could not save route" }
            }
        }
    }

    private func activateConnectivity() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func refreshDaySummary() {
        let decoder = JSONDecoder()
        guard let data = WatchWidgetSharedStore.userDefaults.data(forKey: WatchWidgetSharedStore.snapshotKey),
              let snapshot = try? decoder.decode(WatchTimelineWidgetSnapshot.self, from: data) else {
            daySummary = .placeholder
            syncedRouteCoordinates = []
            return
        }

        daySummary = WatchDaySummary(
            dayTitle: snapshot.dayTitle,
            totalDistanceMeters: max(snapshot.totalDistanceMeters, 0),
            visitedLocationCount: max(snapshot.visitedLocationCount, 0),
            moveCount: max(snapshot.moveCount, 0)
        )
        syncedRouteCoordinates = (snapshot.routePoints ?? []).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private func loadTodayRouteSnapshot() {
        Task { [weak self] in
            guard let self else { return }
            guard let snapshot = try? await routeStore.todaySnapshot(for: .now) else { return }
            await MainActor.run {
                let persisted = self.syncedRouteCoordinates + snapshot.points.map(\.coordinate)
                let current = self.todayRouteCoordinates
                let refreshed = persisted + self.activeSamples.map(\.coordinate)
                // A snapshot can race a just-finished fallback write. Never
                // replace a newer in-memory presentation with that older read.
                self.todayRouteCoordinates = Self.downsample(
                    current.count > refreshed.count ? current : refreshed,
                    maximumCount: 1_200
                )
            }
        }
    }

    private func appendToTodayRouteCache(_ points: [WatchRoutePoint]) {
        guard !points.isEmpty else { return }
        var coordinates = todayRouteCoordinates
        coordinates.append(contentsOf: points.map(\.coordinate))
        todayRouteCoordinates = Self.downsample(coordinates, maximumCount: 1_200)
    }

    private static func downsample(_ points: [CLLocationCoordinate2D], maximumCount: Int) -> [CLLocationCoordinate2D] {
        guard points.count > maximumCount, maximumCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { points[Int((Double($0) * step).rounded())] }
    }
}

extension WatchLocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.statusText = manager.authorizationStatus == .denied ? "Location denied" : self.statusText
            self.startFallbackMonitoring()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.appendLocations(
                locations,
                sourceRawValue: self.isTracking ? "watchRouteTracking" : "watchSignificantChange"
            )
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.statusText = "GPS signal unavailable"
        }
    }
}

extension WatchLocationTracker: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.flushStoredRoutes()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        Task { @MainActor in
            self.routeTransferInProgress = false
            guard error == nil else { return }
            try? await self.routeStore.markTransferred(fileTransfer.file.fileURL)
            self.flushStoredRoutes()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchWidgetSharedStore.snapshotKey] as? Data else { return }
        WatchWidgetSharedStore.userDefaults.set(data, forKey: WatchWidgetSharedStore.snapshotKey)
        Task { @MainActor in
            self.refreshDaySummary()
        }
    }
}

#if DEBUG
extension WatchLocationTracker {
    static func preview(
        isTracking: Bool,
        statusText: String,
        daySummary: WatchDaySummary,
        todayRouteCoordinates: [CLLocationCoordinate2D]
    ) -> WatchLocationTracker {
        let tracker = WatchLocationTracker()
        tracker.isTracking = isTracking
        tracker.statusText = statusText
        tracker.daySummary = daySummary
        tracker.todayRouteCoordinates = todayRouteCoordinates
        tracker.sampleCount = todayRouteCoordinates.count
        tracker.lastHorizontalAccuracy = todayRouteCoordinates.isEmpty ? nil : 8
        return tracker
    }
}
#endif
