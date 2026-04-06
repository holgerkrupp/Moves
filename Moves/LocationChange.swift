import Foundation
import Combine
import CoreLocation
import CoreMotion
import SwiftData

@MainActor
protocol LocationCaptureService: AnyObject {
    func start() async
    func stop()
    func refreshHistoricalBackfill() async
}

protocol MotionClassifier {
    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> TransportMode
    func stepCount(start: Date, end: Date) async -> Int?
}

@MainActor
protocol TimelineAssembler {
    func ingestVisit(_ visit: CLVisit) async
    func ingestLocations(_ locations: [CLLocation], source: LocationSampleSource) async
}

final class CoreMotionTransportClassifier: MotionClassifier {
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()

    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> TransportMode {
        guard end > start else { return .stationary }

        if CMMotionActivityManager.isActivityAvailable(),
           let activities = await queryActivities(from: start, to: end),
           !activities.isEmpty {
            var scores: [TransportMode: Int] = [:]

            for activity in activities {
                let weight = confidenceWeight(for: activity.confidence)
                if activity.automotive { scores[.automotive, default: 0] += weight }
                if activity.cycling { scores[.cycling, default: 0] += weight }
                if activity.running { scores[.running, default: 0] += weight }
                if activity.walking { scores[.walking, default: 0] += weight }
                if activity.stationary { scores[.stationary, default: 0] += weight }
            }

            if let best = scores.max(by: { $0.value < $1.value })?.key {
                return best
            }
        }

        return inferFromSpeed(locations)
    }

    func stepCount(start: Date, end: Date) async -> Int? {
        guard CMPedometer.isStepCountingAvailable(), end > start else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data?.numberOfSteps.intValue)
            }
        }
    }

    private func queryActivities(from start: Date, to end: Date) async -> [CMMotionActivity]? {
        guard end > start else { return nil }

        return await withCheckedContinuation { continuation in
            activityManager.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: activities)
            }
        }
    }

    private func confidenceWeight(for confidence: CMMotionActivityConfidence) -> Int {
        switch confidence {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        @unknown default: return 1
        }
    }

    private func inferFromSpeed(_ locations: [CLLocation]) -> TransportMode {
        let validSpeeds = locations.map(\.speed).filter { $0 >= 0 }

        let averageSpeed: CLLocationSpeed
        if validSpeeds.isEmpty {
            guard
                let first = locations.first,
                let last = locations.last,
                last.timestamp > first.timestamp
            else {
                return .unknown
            }

            let distance = first.distance(from: last)
            averageSpeed = distance / last.timestamp.timeIntervalSince(first.timestamp)
        } else {
            averageSpeed = validSpeeds.reduce(0, +) / Double(validSpeeds.count)
        }

        switch averageSpeed {
        case ..<0.7:
            return .stationary
        case ..<2.0:
            return .walking
        case ..<4.5:
            return .running
        case ..<9.0:
            return .cycling
        default:
            return .automotive
        }
    }
}

@MainActor
final class DefaultTimelineAssembler: TimelineAssembler {
    private let repository: TimelineRepository
    private let motionClassifier: MotionClassifier

    init(repository: TimelineRepository, motionClassifier: MotionClassifier) {
        self.repository = repository
        self.motionClassifier = motionClassifier
    }

    func ingestLocations(_ locations: [CLLocation], source: LocationSampleSource) async {
        guard !locations.isEmpty else { return }

        do {
            _ = try repository.appendSamples(from: locations, source: source)
            try repository.saveIfNeeded()
        } catch {
            print("Failed to persist location samples: \(error.localizedDescription)")
        }
    }

    func ingestVisit(_ visit: CLVisit) async {
        do {
            let visitPlace = try repository.addOrUpdateVisit(from: visit)

            let normalizedArrival = visitPlace.arrivalDate
            guard
                let previousPlace = try repository.latestPlace(
                    before: normalizedArrival,
                    excluding: visitPlace.id
                )
            else {
                try repository.saveIfNeeded()
                return
            }

            let startDate = previousPlace.departureDate ?? previousPlace.arrivalDate
            let endDate = normalizedArrival
            guard endDate.timeIntervalSince(startDate) > 60 else {
                try repository.saveIfNeeded()
                return
            }

            let betweenSamples = try repository.samples(from: startDate, to: endDate)
            let movementLocations = movementLocations(
                startPlace: previousPlace,
                endPlace: visitPlace,
                startDate: startDate,
                endDate: endDate,
                samples: betweenSamples
            )

            let transportMode = await motionClassifier.classifyTransport(
                start: startDate,
                end: endDate,
                locations: movementLocations
            )
            let steps = await motionClassifier.stepCount(start: startDate, end: endDate)
            let totalDistance = Self.totalDistance(for: movementLocations)

            _ = try repository.upsertMove(
                startPlace: previousPlace,
                endPlace: visitPlace,
                startDate: startDate,
                endDate: endDate,
                transportMode: transportMode,
                distanceMeters: totalDistance,
                stepCount: steps,
                samples: betweenSamples
            )

            try repository.saveIfNeeded()
        } catch {
            print("Failed to build timeline segment: \(error.localizedDescription)")
        }
    }

    private func movementLocations(
        startPlace: VisitPlace,
        endPlace: VisitPlace,
        startDate: Date,
        endDate: Date,
        samples: [LocationSample]
    ) -> [CLLocation] {
        let orderedSamples = samples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map(\.asLocation)

        let start = CLLocation(
            coordinate: startPlace.coordinate,
            altitude: 0,
            horizontalAccuracy: max(startPlace.horizontalAccuracy, 20),
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: startDate
        )

        let end = CLLocation(
            coordinate: endPlace.coordinate,
            altitude: 0,
            horizontalAccuracy: max(endPlace.horizontalAccuracy, 20),
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: endDate
        )

        return [start] + orderedSamples + [end]
    }

    private static func totalDistance(for locations: [CLLocation]) -> CLLocationDistance {
        guard locations.count > 1 else { return 0 }

        return zip(locations, locations.dropFirst()).reduce(0) { partialResult, pair in
            partialResult + pair.0.distance(from: pair.1)
        }
    }
}

@MainActor
final class MovesLocationCaptureManager: NSObject, ObservableObject, LocationCaptureService {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var lastErrorMessage: String?

    private let manager = CLLocationManager()
    private let assembler: TimelineAssembler
    private var pendingBackfillResponse = false

    init(modelContainer: ModelContainer) {
        let repository = SwiftDataTimelineRepository(modelContainer: modelContainer)
        self.assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: CoreMotionTransportClassifier()
        )

        super.init()

        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 150
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false

        authorizationStatus = manager.authorizationStatus
    }

    var trackingStatusText: String {
        switch authorizationStatus {
        case .authorizedAlways:
            return isMonitoring ? "Tracking in background" : "Ready"
        case .authorizedWhenInUse:
            return "Tracking only while app is active"
        case .denied:
            return "Location access denied"
        case .restricted:
            return "Location access restricted"
        case .notDetermined:
            return "Waiting for location permission"
        @unknown default:
            return "Unknown location state"
        }
    }

    func start() async {
        handleAuthorization(manager.authorizationStatus)
    }

    func stop() {
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        isMonitoring = false
    }

    func refreshHistoricalBackfill() async {
        guard isAuthorizedForTracking else { return }

        // iOS does not expose requestHistoricalLocations for third-party apps.
        // We ask for one current fix on launch/foreground to bridge short gaps.
        pendingBackfillResponse = true
        manager.requestLocation()
    }

    private var isAuthorizedForTracking: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status

        switch status {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startLowPowerMonitoringIfNeeded()
        case .restricted, .denied:
            stop()
        @unknown default:
            stop()
        }
    }

    private func startLowPowerMonitoringIfNeeded() {
        guard !isMonitoring else { return }

        manager.startMonitoringVisits()
        manager.startMonitoringSignificantLocationChanges()
        isMonitoring = true
    }
}

extension MovesLocationCaptureManager: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let visitTimestamp = visit.arrivalDate == .distantPast ? Date.now : visit.arrivalDate
        let visitLocation = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: max(visit.horizontalAccuracy, 20),
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: visitTimestamp
        )

        lastCaptureAt = .now

        Task {
            await assembler.ingestLocations([visitLocation], source: .visit)
            await assembler.ingestVisit(visit)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }

        lastCaptureAt = .now
        let source: LocationSampleSource = pendingBackfillResponse ? .launchBackfill : .significantChange
        pendingBackfillResponse = false

        Task {
            await assembler.ingestLocations(locations, source: source)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError

        if nsError.domain == kCLErrorDomain,
           nsError.code == CLError.locationUnknown.rawValue {
            return
        }

        lastErrorMessage = error.localizedDescription
    }
}
