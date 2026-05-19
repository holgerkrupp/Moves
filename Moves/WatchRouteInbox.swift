import Foundation
import CoreLocation
import SwiftData
import WatchConnectivity
import WidgetKit

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

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            course: -1,
            speed: speed,
            timestamp: timestamp
        )
    }
}

@MainActor
final class WatchRouteInbox: NSObject, ObservableObject {
    @Published private(set) var lastImportAt: Date?
    @Published private(set) var lastImportSummary: String?

    private let modelContainer: ModelContainer
    private let decoder = JSONDecoder()

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        super.init()
        activateSessionIfSupported()
    }

    private func activateSessionIfSupported() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func importPayloadData(_ data: Data) {
        do {
            let payload = try decoder.decode(WatchRoutePayload.self, from: data)
            let locations = payload.samples.map(\.location)
            let repository = SwiftDataTimelineRepository(modelContainer: modelContainer)
            let source = LocationSampleSource(rawValue: payload.sourceRawValue) ?? .watchRouteTracking

            _ = try repository.importRouteTrack(
                locations: locations,
                source: source,
                transportMode: .unknown
            )
            try repository.saveIfNeeded()

            lastImportAt = .now
            lastImportSummary = "Imported \(locations.count) watch GPS point(s)."
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastImportSummary = "Watch route import failed: \(error.localizedDescription)"
        }
    }
}

extension WatchRouteInbox: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in
            self.importPayloadData(data)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["routePayload"] as? Data else { return }
        Task { @MainActor in
            self.importPayloadData(data)
        }
    }
}
