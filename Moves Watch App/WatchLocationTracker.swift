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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var activeSamples: [CLLocation] = []
    private var activeStartedAt: Date?
    private var syncedRouteCoordinates: [CLLocationCoordinate2D] = []

    override init() {
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
        refreshTodayRouteCoordinates()
    }

    func flushStoredRoutes() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        for fileURL in storedRouteFileURLs() {
            session.transferFile(fileURL, metadata: nil)
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
        refreshTodayRouteCoordinates()
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
        refreshTodayRouteCoordinates()
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

        do {
            let data = try encoder.encode(payload)
            let fileURL = routesDirectory
                .appendingPathComponent(payload.id.uuidString)
                .appendingPathExtension("json")
            try FileManager.default.createDirectory(
                at: routesDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            flushStoredRoutes()
            refreshTodayRouteCoordinates()
        } catch {
            statusText = "Could not save route"
        }
    }

    private func activateConnectivity() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private var routesDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WatchRoutes", isDirectory: true)
    }

    private func storedRouteFileURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: routesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private func refreshDaySummary() {
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

    private func refreshTodayRouteCoordinates() {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            todayRouteCoordinates = activeSamples.map(\.coordinate)
            return
        }

        var coordinates: [CLLocationCoordinate2D] = syncedRouteCoordinates
        for fileURL in storedRouteFileURLs() {
            guard let data = try? Data(contentsOf: fileURL),
                  let payload = try? decoder.decode(WatchRoutePayload.self, from: data),
                  payload.endedAt >= startOfDay,
                  payload.startedAt < endOfDay else {
                continue
            }
            coordinates.append(contentsOf: payload.samples.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            })
        }

        coordinates.append(contentsOf: activeSamples.map(\.coordinate))
        todayRouteCoordinates = coordinates
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
            self.refreshDaySummary()
            self.refreshTodayRouteCoordinates()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard error == nil else { return }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchWidgetSharedStore.snapshotKey] as? Data else { return }
        WatchWidgetSharedStore.userDefaults.set(data, forKey: WatchWidgetSharedStore.snapshotKey)
        Task { @MainActor in
            self.refreshDaySummary()
            self.refreshTodayRouteCoordinates()
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
