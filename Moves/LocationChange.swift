import Foundation
import Combine
import CoreLocation
import CoreMotion
import MapKit
import SwiftData
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

@MainActor
protocol LocationCaptureService: AnyObject {
    func start() async
    func requestTrackingAuthorization()
    func enableTemporaryRouteTracking(duration: TemporaryRouteTrackingDuration)
    func updateTemporaryRouteTrackingAutoStopRules(
        stopsAtFiftyPercentBattery: Bool,
        stopsInLowPowerMode: Bool
    )
    func disableTemporaryRouteTracking()
    func stop()
    func refreshHistoricalBackfill() async
}

enum TemporaryRouteTrackingDuration: String, CaseIterable, Identifiable {
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case endOfDay

    var id: String { rawValue }

    var title: String {
        guard let timeInterval else { return String(localized: "Until end of day") }
        return DurationFormatter.wideText(for: timeInterval)
    }

    var availabilityText: String {
        guard timeInterval != nil else { return String(localized: "until the end of today") }
        return String(localized: "for \(title)")
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .thirtyMinutes:
            return 30 * 60
        case .oneHour:
            return 60 * 60
        case .twoHours:
            return 2 * 60 * 60
        case .fourHours:
            return 4 * 60 * 60
        case .endOfDay:
            return nil
        }
    }

    func endDate(from startDate: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        switch self {
        case .thirtyMinutes:
            return startDate.addingTimeInterval(30 * 60)
        case .oneHour:
            return startDate.addingTimeInterval(60 * 60)
        case .twoHours:
            return startDate.addingTimeInterval(2 * 60 * 60)
        case .fourHours:
            return startDate.addingTimeInterval(4 * 60 * 60)
        case .endOfDay:
            let startOfDay = calendar.startOfDay(for: startDate)
            return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(24 * 60 * 60)
        }
    }
}

enum TemporaryRouteTrackingStopNotificationPermissionResult: Equatable {
    case enabled
    case needsSettings
}

protocol MotionClassifier {
    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> TransportMode
    func stepCount(start: Date, end: Date) async -> Int?
}

@MainActor
protocol TimelineAssembler {
    func ingestVisit(_ visit: CLVisit) async
    func ingestLocations(_ locations: [CLLocation], source: LocationSampleSource) async
    func fillVisitGaps(onDayWithKey dayKey: String) async -> Int
}

enum VisitGapFillingSettings {
    static let isEnabledKey = "Moves.visitGapFilling.isEnabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: isEnabledKey)
    }
}

final class CoreMotionTransportClassifier: MotionClassifier {
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private static let minimumDistanceForNonStationaryOverride: CLLocationDistance = 450
    private static let minimumWalkingEvidenceDuration: TimeInterval = 8 * 60

    func classifyTransport(start: Date, end: Date, locations: [CLLocation]) async -> TransportMode {
        guard end > start else { return .stationary }
        let fallback = inferFromSpeed(locations)

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
                let corrected = correctedModeIfNeeded(best, fallback: fallback, locations: locations)
                return refinedLongDistanceMode(for: corrected, fallback: fallback, locations: locations)
            }
        }

        let corrected = correctedModeIfNeeded(fallback, fallback: fallback, locations: locations)
        return refinedLongDistanceMode(for: corrected, fallback: fallback, locations: locations)
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
        case ..<32:
            return .automotive
        case ..<75:
            return .train
        default:
            return .plane
        }
    }

    private func correctedModeIfNeeded(
        _ candidate: TransportMode,
        fallback: TransportMode,
        locations: [CLLocation]
    ) -> TransportMode {
        // Core Motion can report the automotive activity that preceded a walk when
        // the visit-to-visit window is assembled from sparse significant-location
        // samples. A sustained, kilometre-scale low-speed trace is stronger
        // evidence for the leg represented by this window than that stale label.
        if (candidate == .automotive || candidate == .running || candidate == .cycling
            || (candidate == .stationary && fallback == .automotive)),
           walkingLocationEvidence(locations) {
            return .walking
        }

        guard candidate == .stationary else { return candidate }

        let traveledDistance = Self.totalDistance(for: locations)
        guard traveledDistance >= Self.minimumDistanceForNonStationaryOverride else {
            return candidate
        }

        if fallback != .stationary && fallback != .unknown {
            return fallback
        }

        let maxObservedSpeed = locations
            .map(\.speed)
            .filter { $0 >= 0 }
            .max() ?? -1

        switch maxObservedSpeed {
        case 9...:
            return .automotive
        case 4.5...:
            return .cycling
        case 2.0...:
            return .running
        case 0.8...:
            return .walking
        default:
            break
        }

        let directDistance = Self.straightLineDistance(for: locations)
        if directDistance >= 1_500 {
            return .automotive
        }
        if directDistance >= 500 {
            return .cycling
        }
        return .walking
    }

    private func walkingLocationEvidence(_ locations: [CLLocation]) -> Bool {
        guard locations.count >= 2,
              let first = locations.first,
              let last = locations.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= Self.minimumWalkingEvidenceDuration,
              Self.totalDistance(for: locations) >= Self.minimumDistanceForNonStationaryOverride
        else {
            return false
        }

        let validSpeeds = locations
            .map(\.speed)
            .filter { $0 >= 0 }
            .sorted()

        let medianSpeed: CLLocationSpeed
        if validSpeeds.isEmpty {
            medianSpeed = Self.totalDistance(for: locations)
                / last.timestamp.timeIntervalSince(first.timestamp)
        } else {
            let middle = validSpeeds.count / 2
            medianSpeed = validSpeeds.count.isMultiple(of: 2)
                ? (validSpeeds[middle - 1] + validSpeeds[middle]) / 2
                : validSpeeds[middle]
        }

        return (0.7...2.2).contains(medianSpeed)
    }

    private func refinedLongDistanceMode(
        for candidate: TransportMode,
        fallback: TransportMode,
        locations: [CLLocation]
    ) -> TransportMode {
        switch candidate {
        case .walking, .running, .swimming, .cycling, .train, .plane, .boat:
            return candidate
        case .stationary, .automotive, .motorcycle, .unknown:
            break
        }

        let directDistance = Self.straightLineDistance(for: locations)
        let averageSpeed = Self.averageSpeed(for: locations)
        let maxObservedSpeed = Self.maxObservedSpeed(for: locations)
        let baseline = candidate == .stationary ? fallback : candidate

        if maxObservedSpeed >= 80 ||
            averageSpeed >= 55 ||
            (directDistance >= 120_000 && averageSpeed >= 40) {
            return .plane
        }

        if averageSpeed >= 16 &&
            directDistance >= 18_000 &&
            baseline != .cycling &&
            baseline != .walking &&
            baseline != .running {
            return .train
        }

        return candidate
    }

    private static func totalDistance(for locations: [CLLocation]) -> CLLocationDistance {
        guard locations.count > 1 else { return 0 }
        return zip(locations, locations.dropFirst()).reduce(0) { partialResult, pair in
            partialResult + pair.0.distance(from: pair.1)
        }
    }

    private static func averageSpeed(for locations: [CLLocation]) -> CLLocationSpeed {
        let validSpeeds = locations.map(\.speed).filter { $0 >= 0 }
        if !validSpeeds.isEmpty {
            return validSpeeds.reduce(0, +) / Double(validSpeeds.count)
        }

        guard
            let first = locations.first,
            let last = locations.last,
            last.timestamp > first.timestamp
        else {
            return 0
        }

        return first.distance(from: last) / last.timestamp.timeIntervalSince(first.timestamp)
    }

    private static func maxObservedSpeed(for locations: [CLLocation]) -> CLLocationSpeed {
        locations
            .map(\.speed)
            .filter { $0 >= 0 }
            .max() ?? 0
    }

    private static func straightLineDistance(for locations: [CLLocation]) -> CLLocationDistance {
        guard let first = locations.first, let last = locations.last else { return 0 }
        return first.distance(from: last)
    }
}

@MainActor
final class DefaultTimelineAssembler: TimelineAssembler {
    private let repository: TimelineRepository
    private let motionClassifier: MotionClassifier
    private let placeNameResolver: PlaceNameResolver
    private let automaticallyFillsVisitGaps: () -> Bool

    init(
        repository: TimelineRepository,
        motionClassifier: MotionClassifier,
        placeNameResolver: PlaceNameResolver,
        automaticallyFillsVisitGaps: @escaping () -> Bool = {
            VisitGapFillingSettings.isEnabled()
        }
    ) {
        self.repository = repository
        self.motionClassifier = motionClassifier
        self.placeNameResolver = placeNameResolver
        self.automaticallyFillsVisitGaps = automaticallyFillsVisitGaps
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
            await fillAutomaticPlaceLabelIfNeeded(for: visitPlace)

            guard automaticallyFillsVisitGaps() else {
                try repository.saveIfNeeded()
                return
            }

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

            _ = try await fillGap(from: previousPlace, to: visitPlace)
            try repository.saveIfNeeded()
        } catch {
            print("Failed to build timeline segment: \(error.localizedDescription)")
        }
    }

    func fillVisitGaps(onDayWithKey dayKey: String) async -> Int {
        do {
            let places = try repository.placesForGapFilling(onDayWithKey: dayKey)
            guard places.count > 1 else { return 0 }

            var filledGapCount = 0
            for (startPlace, endPlace) in zip(places, places.dropFirst()) {
                if try await fillGap(from: startPlace, to: endPlace) {
                    filledGapCount += 1
                }
            }

            try repository.saveIfNeeded()
            return filledGapCount
        } catch {
            print("Failed to fill visit gaps: \(error.localizedDescription)")
            return 0
        }
    }

    private func fillGap(from previousPlace: VisitPlace, to visitPlace: VisitPlace) async throws -> Bool {
        let alreadyHasConnectingMove = previousPlace.outgoingMoves.contains {
            $0.endPlace?.id == visitPlace.id
        } || visitPlace.incomingMoves.contains {
            $0.startPlace?.id == previousPlace.id
        }
        guard !alreadyHasConnectingMove else { return false }

        let endDate = visitPlace.arrivalDate

        if previousPlace.departureDate == nil {
            let candidateSamples = try repository.samples(from: previousPlace.arrivalDate, to: endDate)
            previousPlace.departureDate = inferredDepartureDate(
                for: previousPlace,
                endDate: endDate,
                samples: candidateSamples
            )
        }

        let candidateStartDate = previousPlace.departureDate ?? previousPlace.arrivalDate
        let startDate = min(max(candidateStartDate, previousPlace.arrivalDate), endDate)

        guard endDate > startDate else { return false }

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

        return true
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

    private func inferredDepartureDate(
        for place: VisitPlace,
        endDate: Date,
        samples: [LocationSample]
    ) -> Date {
        let sortedSamples = samples.sorted(by: { $0.timestamp < $1.timestamp })
        let departureRadius = max(place.horizontalAccuracy * 1.8, 80)

        if let firstAwaySample = sortedSamples.first(where: { sample in
            guard sample.timestamp >= place.arrivalDate else { return false }
            let sampleLocation = sample.asLocation
            let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            return sampleLocation.distance(from: placeLocation) >= departureRadius
        }) {
            return min(firstAwaySample.timestamp, endDate)
        }

        return endDate
    }

    private func fillAutomaticPlaceLabelIfNeeded(for place: VisitPlace) async {
        let hasUserLabel = !(place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasAutoLabel = !(place.autoLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        guard !hasUserLabel, !hasAutoLabel else { return }
        guard place.horizontalAccuracy <= 180 else { return }

        if let resolvedName = await placeNameResolver.resolveName(for: place.coordinate) {
            do {
                try repository.setAutomaticLabel(resolvedName, for: place.id)
                try repository.saveIfNeeded()
            } catch {
                print("Failed to persist automatic place label: \(error.localizedDescription)")
            }
        }
    }
}

@MainActor
final class MovesLocationCaptureManager: NSObject, ObservableObject, LocationCaptureService {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isMonitoring = false
    @Published private(set) var isBackgroundLocationListeningEnabled = true
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var temporaryRouteTrackingDuration: TemporaryRouteTrackingDuration = .endOfDay
    @Published private(set) var temporaryRouteTrackingStartedAt: Date?
    @Published private(set) var temporaryRouteTrackingEndsAt: Date?
    @Published private(set) var temporaryRouteTrackingStopsAtFiftyPercentBattery = false
    @Published private(set) var temporaryRouteTrackingStopsInLowPowerMode = false
    @Published private(set) var temporaryRouteTrackingStopNotificationEnabled = false

    private let manager = CLLocationManager()
    private let userDefaults: UserDefaults
    #if targetEnvironment(simulator)
    let isDemoMode = true
    #else
    let isDemoMode = false
    #endif
    private let assembler: TimelineAssembler
    private let routeTrackingLiveActivity = RouteTrackingLiveActivityCoordinator()
    private var pendingOneShotLocationSource: LocationSampleSource?
    private var pendingTemporaryRouteTrackingDuration: TemporaryRouteTrackingDuration?
    private var shouldChainToAlwaysAfterWhenInUse = false
    private var isHighAccuracyMonitoring = false
    private var temporaryRouteTrackingExpiryTask: Task<Void, Never>?
    private var temporaryRouteTrackingEnergyStateObserverTokens: [NSObjectProtocol] = []

    var isLocationTrackingAvailable: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        true
        #endif
    }

    private enum TemporaryRouteTrackingStorageKey {
        static let duration = "Moves.temporaryRouteTracking.duration"
        static let startedAt = "Moves.temporaryRouteTracking.startedAt"
        static let endsAt = "Moves.temporaryRouteTracking.endsAt"
        static let stopAtFiftyPercentBattery = "Moves.temporaryRouteTracking.stopAtFiftyPercentBattery"
        static let stopInLowPowerMode = "Moves.temporaryRouteTracking.stopInLowPowerMode"
        static let stopNotificationEnabled = "Moves.temporaryRouteTracking.stopNotificationEnabled"
    }

    enum BackgroundLocationListeningSettings {
        static let isEnabledKey = "Moves.backgroundLocationListening.isEnabled"
        static let roleWasChosenKey = "Moves.backgroundLocationListening.roleWasChosen"
    }

    private static let stopNotificationIdentifier = "Moves.temporaryRouteTracking.stoppedNotification"

    private static let lowPowerDesiredAccuracy = kCLLocationAccuracyHundredMeters
    private static let lowPowerDistanceFilter: CLLocationDistance = 150
    private static let highAccuracyDesiredAccuracy = kCLLocationAccuracyBestForNavigation
    private static let highAccuracyDistanceFilter: CLLocationDistance = 10

    private var shouldSkipLiveTracking: Bool {
        !isLocationTrackingAvailable || isDemoMode || ProcessInfo.processInfo.isRunningUnitTests
    }

    private var shouldSkipAuthorizationRequest: Bool {
        !isLocationTrackingAvailable || ProcessInfo.processInfo.isRunningUnitTests
    }

    init(modelContainer: ModelContainer, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let repository = SwiftDataTimelineRepository(modelContainer: modelContainer)
        self.assembler = DefaultTimelineAssembler(
            repository: repository,
            motionClassifier: CoreMotionTransportClassifier(),
            placeNameResolver: CLGeocoderPlaceNameResolver(),
            automaticallyFillsVisitGaps: {
                VisitGapFillingSettings.isEnabled(userDefaults: userDefaults)
            }
        )

        super.init()

        guard isLocationTrackingAvailable else {
            authorizationStatus = .restricted
            isBackgroundLocationListeningEnabled = false
            return
        }

        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = Self.lowPowerDesiredAccuracy
        manager.distanceFilter = Self.lowPowerDistanceFilter
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = false

        authorizationStatus = manager.authorizationStatus
        if !shouldSkipLiveTracking {
            UIDevice.current.isBatteryMonitoringEnabled = true
            installTemporaryRouteTrackingEnergyObservers()
        }
        restoreTemporaryRouteTrackingState()
        migrateExistingTrackingConsentIfNeeded()
        restoreBackgroundLocationListeningState()
        updateBackgroundLocationAllowance()
    }

    @discardableResult
    func fillVisitGaps(onDayWithKey dayKey: String) async -> Int {
        await assembler.fillVisitGaps(onDayWithKey: dayKey)
    }

    var trackingStatusText: String {
        if isDemoMode {
            return "Simulator demo mode"
        }

        if isTemporaryRouteTrackingActive {
            switch authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                return "Real route tracking on"
            case .notDetermined:
                return "Real route tracking waiting for permission"
            case .denied, .restricted:
                return "Real route tracking paused"
            @unknown default:
                return "Real route tracking on"
            }
        }

        switch authorizationStatus {
        case .authorizedAlways:
            if isMonitoring {
                return "Tracking in background"
            }
            return isBackgroundLocationListeningEnabled ? "Ready" : "Background listening off"
        case .authorizedWhenInUse:
            return isBackgroundLocationListeningEnabled
                ? "Tracking only while app is active"
                : "Background listening off"
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
        guard !shouldSkipLiveTracking else { return }
        // The device role must be chosen before Moves can ask iOS for location
        // access. This keeps the system prompt behind the app's own consent.
        guard isTrackingRoleDecided else { return }
        guard isBackgroundLocationListeningEnabled else {
            stop()
            return
        }

        let status = manager.authorizationStatus
        handleAuthorization(status)
        scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
        await routeTrackingLiveActivity.synchronize(
            startedAt: temporaryRouteTrackingStartedAt,
            endsAt: temporaryRouteTrackingEndsAt
        )

        if status == .notDetermined {
            requestTrackingAuthorization()
        }
    }

    func requestTrackingAuthorization() {
        // Simulator demo mode still needs to exercise the real permission
        // flow; only live sample capture is disabled there.
        guard !shouldSkipAuthorizationRequest else { return }
        guard isBackgroundLocationListeningEnabled else {
            stop()
            return
        }

        let status = manager.authorizationStatus
        authorizationStatus = status
        updateBackgroundLocationAllowance()

        switch status {
        case .notDetermined:
            shouldChainToAlwaysAfterWhenInUse = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            shouldChainToAlwaysAfterWhenInUse = false
            guard !shouldSkipLiveTracking else { return }
            manager.requestAlwaysAuthorization()
            applyTrackingConfiguration()
            requestOneShotLocation(source: .authorizationGrant)
        case .authorizedAlways:
            shouldChainToAlwaysAfterWhenInUse = false
            guard !shouldSkipLiveTracking else { return }
            applyTrackingConfiguration()
            requestOneShotLocation(source: .authorizationGrant)
        case .restricted, .denied:
            shouldChainToAlwaysAfterWhenInUse = false
            stop()
        @unknown default:
            shouldChainToAlwaysAfterWhenInUse = false
        }
    }

    func stop() {
        guard !shouldSkipLiveTracking else { return }

        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        pendingOneShotLocationSource = nil
        isMonitoring = false
        isHighAccuracyMonitoring = false
    }

    func setBackgroundLocationListeningEnabled(_ isEnabled: Bool) {
        guard isLocationTrackingAvailable else {
            isBackgroundLocationListeningEnabled = false
            return
        }

        isBackgroundLocationListeningEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: BackgroundLocationListeningSettings.isEnabledKey)
        userDefaults.set(true, forKey: BackgroundLocationListeningSettings.roleWasChosenKey)

        if isEnabled && !isAuthorizedForTracking {
            requestTrackingAuthorization()
            return
        }

        guard !shouldSkipLiveTracking else { return }

        applyTrackingConfiguration()
    }

    func refreshHistoricalBackfill() async {
        guard !shouldSkipLiveTracking else { return }
        guard isBackgroundLocationListeningEnabled else { return }

        guard isAuthorizedForTracking else { return }

        // iOS does not expose requestHistoricalLocations for third-party apps.
        // We ask for one current fix on launch/foreground to bridge short gaps.
        requestOneShotLocation(source: .launchBackfill)
    }

    func enableTemporaryRouteTracking(duration: TemporaryRouteTrackingDuration) {
        guard !shouldSkipLiveTracking else { return }
        guard isBackgroundLocationListeningEnabled else { return }
        guard isAuthorizedForTracking else {
            if authorizationStatus == .notDetermined {
                pendingTemporaryRouteTrackingDuration = duration
                requestTrackingAuthorization()
            }
            return
        }

        pendingTemporaryRouteTrackingDuration = nil

        temporaryRouteTrackingDuration = duration
        temporaryRouteTrackingStartedAt = .now
        temporaryRouteTrackingEndsAt = duration.endDate(from: .now)
        persistTemporaryRouteTrackingState()

        if shouldExpireTemporaryRouteTrackingNow {
            expireTemporaryRouteTracking(notifyImmediately: true)
            return
        }

        scheduleTemporaryRouteTrackingExpiryTask()
        scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
        applyTrackingConfiguration()
        requestOneShotLocation(source: .routeTracking)
        Task {
            await routeTrackingLiveActivity.synchronize(
                startedAt: temporaryRouteTrackingStartedAt,
                endsAt: temporaryRouteTrackingEndsAt
            )
        }
    }

    func enableTemporaryRouteTrackingStopNotifications() async -> TemporaryRouteTrackingStopNotificationPermissionResult {
        guard !shouldSkipLiveTracking else { return .enabled }

        temporaryRouteTrackingStopNotificationEnabled = true
        persistTemporaryRouteTrackingState()

        let status = await notificationAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
            return .enabled
        case .notDetermined:
            let granted = await requestNotificationAuthorization()
            if granted {
                scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
                return .enabled
            }
            cancelTemporaryRouteTrackingStoppedNotification()
            return .needsSettings
        case .denied:
            cancelTemporaryRouteTrackingStoppedNotification()
            return .needsSettings
        @unknown default:
            cancelTemporaryRouteTrackingStoppedNotification()
            return .needsSettings
        }
    }

    func disableTemporaryRouteTrackingStopNotifications() {
        guard !shouldSkipLiveTracking else { return }

        temporaryRouteTrackingStopNotificationEnabled = false
        persistTemporaryRouteTrackingState()
        cancelTemporaryRouteTrackingStoppedNotification()
    }

    func updateTemporaryRouteTrackingAutoStopRules(
        stopsAtFiftyPercentBattery: Bool,
        stopsInLowPowerMode: Bool
    ) {
        guard !shouldSkipLiveTracking else { return }

        temporaryRouteTrackingStopsAtFiftyPercentBattery = stopsAtFiftyPercentBattery
        temporaryRouteTrackingStopsInLowPowerMode = stopsInLowPowerMode
        persistTemporaryRouteTrackingState()
        refreshTemporaryRouteTrackingStateIfNeeded()
    }

    func disableTemporaryRouteTracking() {
        guard !shouldSkipLiveTracking else { return }
        guard temporaryRouteTrackingEndsAt != nil else { return }

        cancelTemporaryRouteTrackingExpiryTask()
        temporaryRouteTrackingStartedAt = nil
        temporaryRouteTrackingEndsAt = nil
        persistTemporaryRouteTrackingState()
        notifyTemporaryRouteTrackingStoppedImmediatelyIfNeeded()
        applyTrackingConfiguration()
        Task {
            await routeTrackingLiveActivity.end()
        }
    }

    func applyMultiDeviceLocationRole(_ role: MultiDeviceLocationRole) {
        switch role {
        case .tracking:
            setBackgroundLocationListeningEnabled(true)
            // setBackgroundLocationListeningEnabled starts the permission flow
            // when needed; this also resumes monitoring immediately for a
            // previously authorized device.
            Task { await start() }
        case .management:
            pendingTemporaryRouteTrackingDuration = nil
            cancelTemporaryRouteTrackingExpiryTask()
            temporaryRouteTrackingStartedAt = nil
            temporaryRouteTrackingEndsAt = nil
            persistTemporaryRouteTrackingState()
            setBackgroundLocationListeningEnabled(false)
            stop()
            Task { await routeTrackingLiveActivity.end() }
        }
    }

    private var isAuthorizedForTracking: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    var isTrackingRoleDecided: Bool {
        userDefaults.bool(forKey: BackgroundLocationListeningSettings.roleWasChosenKey)
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        updateBackgroundLocationAllowance()
        refreshTemporaryRouteTrackingStateIfNeeded()

        if shouldSkipLiveTracking {
            if status == .authorizedWhenInUse && shouldChainToAlwaysAfterWhenInUse {
                shouldChainToAlwaysAfterWhenInUse = false
                manager.requestAlwaysAuthorization()
            } else if status != .notDetermined {
                shouldChainToAlwaysAfterWhenInUse = false
            }
            return
        }

        switch status {
        case .notDetermined:
            stop()
        case .authorizedAlways:
            shouldChainToAlwaysAfterWhenInUse = false
            applyTrackingConfiguration()
            requestOneShotLocation(source: .authorizationGrant)
            startPendingTemporaryRouteTrackingIfNeeded()
        case .authorizedWhenInUse:
            if shouldChainToAlwaysAfterWhenInUse {
                shouldChainToAlwaysAfterWhenInUse = false
                manager.requestAlwaysAuthorization()
            }

            applyTrackingConfiguration()
            requestOneShotLocation(source: .authorizationGrant)
            startPendingTemporaryRouteTrackingIfNeeded()
        case .restricted, .denied:
            shouldChainToAlwaysAfterWhenInUse = false
            pendingTemporaryRouteTrackingDuration = nil
            stop()
        @unknown default:
            shouldChainToAlwaysAfterWhenInUse = false
            stop()
        }
    }

    private func startPendingTemporaryRouteTrackingIfNeeded() {
        guard let duration = pendingTemporaryRouteTrackingDuration else { return }
        pendingTemporaryRouteTrackingDuration = nil
        enableTemporaryRouteTracking(duration: duration)
    }

    private func startLowPowerMonitoringIfNeeded() {
        guard isBackgroundLocationListeningEnabled else {
            manager.stopMonitoringVisits()
            isMonitoring = false
            return
        }
        guard !isMonitoring else { return }

        manager.startMonitoringVisits()
        isMonitoring = true
    }

    private func applyTrackingConfiguration() {
        guard isAuthorizedForTracking else {
            stop()
            return
        }

        startLowPowerMonitoringIfNeeded()
        updateBackgroundLocationAllowance()

        let shouldUseHighAccuracy = isTemporaryRouteTrackingActive
        if shouldUseHighAccuracy {
            manager.stopMonitoringSignificantLocationChanges()
            manager.desiredAccuracy = Self.highAccuracyDesiredAccuracy
            manager.distanceFilter = Self.highAccuracyDistanceFilter
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = authorizationStatus == .authorizedAlways

            if !isHighAccuracyMonitoring {
                manager.startUpdatingLocation()
                isHighAccuracyMonitoring = true
            }
        } else {
            if isBackgroundLocationListeningEnabled {
                manager.startMonitoringSignificantLocationChanges()
            } else {
                manager.stopMonitoringSignificantLocationChanges()
                manager.stopMonitoringVisits()
                isMonitoring = false
            }
            manager.stopUpdatingLocation()
            isHighAccuracyMonitoring = false
            manager.desiredAccuracy = Self.lowPowerDesiredAccuracy
            manager.distanceFilter = Self.lowPowerDistanceFilter
            manager.pausesLocationUpdatesAutomatically = true
            manager.showsBackgroundLocationIndicator = false
        }
    }

    private func requestOneShotLocation(source: LocationSampleSource) {
        guard isAuthorizedForTracking else { return }

        pendingOneShotLocationSource = source
        manager.requestLocation()
    }

    private func updateBackgroundLocationAllowance() {
        guard !shouldSkipLiveTracking else {
            manager.allowsBackgroundLocationUpdates = false
            return
        }

        manager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
            && (isBackgroundLocationListeningEnabled || isTemporaryRouteTrackingActive)
    }

    private func restoreBackgroundLocationListeningState() {
        if userDefaults.object(forKey: BackgroundLocationListeningSettings.isEnabledKey) == nil {
            // A fresh installation must first ask whether this device should
            // track. Do not let startup trigger the iOS location prompt.
            isBackgroundLocationListeningEnabled = false
        } else {
            isBackgroundLocationListeningEnabled = userDefaults.bool(
                forKey: BackgroundLocationListeningSettings.isEnabledKey
            )
        }
    }

    private func migrateExistingTrackingConsentIfNeeded() {
        guard userDefaults.object(
            forKey: BackgroundLocationListeningSettings.roleWasChosenKey
        ) == nil else { return }

        guard authorizationStatus == .authorizedAlways ||
                authorizationStatus == .authorizedWhenInUse else {
            return
        }

        // Existing installations may already have location permission but no
        // value for the newly introduced device-role preference. Preserve the
        // established behavior instead of showing onboarding again.
        userDefaults.set(true, forKey: BackgroundLocationListeningSettings.roleWasChosenKey)
        if userDefaults.object(forKey: BackgroundLocationListeningSettings.isEnabledKey) == nil {
            userDefaults.set(true, forKey: BackgroundLocationListeningSettings.isEnabledKey)
        }
    }

    var isTemporaryRouteTrackingActive: Bool {
        guard let endsAt = temporaryRouteTrackingEndsAt else { return false }
        return endsAt > .now
    }

    private func refreshTemporaryRouteTrackingStateIfNeeded() {
        guard let endsAt = temporaryRouteTrackingEndsAt else { return }

        if endsAt <= .now {
            expireTemporaryRouteTracking()
            return
        }

        if shouldExpireTemporaryRouteTrackingNow {
            expireTemporaryRouteTracking(notifyImmediately: true)
        }
    }

    private func restoreTemporaryRouteTrackingState() {
        if let durationRawValue = userDefaults.string(forKey: TemporaryRouteTrackingStorageKey.duration),
           let duration = TemporaryRouteTrackingDuration(rawValue: durationRawValue) {
            temporaryRouteTrackingDuration = duration
        }

        temporaryRouteTrackingStartedAt = userDefaults.object(
            forKey: TemporaryRouteTrackingStorageKey.startedAt
        ) as? Date

        temporaryRouteTrackingStopsAtFiftyPercentBattery = userDefaults.bool(
            forKey: TemporaryRouteTrackingStorageKey.stopAtFiftyPercentBattery
        )
        temporaryRouteTrackingStopsInLowPowerMode = userDefaults.bool(
            forKey: TemporaryRouteTrackingStorageKey.stopInLowPowerMode
        )
        temporaryRouteTrackingStopNotificationEnabled = userDefaults.bool(
            forKey: TemporaryRouteTrackingStorageKey.stopNotificationEnabled
        )

        guard let storedEndsAt = userDefaults.object(forKey: TemporaryRouteTrackingStorageKey.endsAt) as? Date else {
            return
        }

        if storedEndsAt > .now {
            temporaryRouteTrackingEndsAt = storedEndsAt
            if temporaryRouteTrackingStartedAt == nil,
               let interval = temporaryRouteTrackingDuration.timeInterval {
                temporaryRouteTrackingStartedAt = storedEndsAt.addingTimeInterval(-interval)
            }
            if shouldExpireTemporaryRouteTrackingNow {
                expireTemporaryRouteTracking(notifyImmediately: true)
                return
            }
            scheduleTemporaryRouteTrackingExpiryTask()
            scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded()
            return
        }

        temporaryRouteTrackingEndsAt = nil
        persistTemporaryRouteTrackingState()
    }

    private func scheduleTemporaryRouteTrackingExpiryTask() {
        cancelTemporaryRouteTrackingExpiryTask()

        guard let endsAt = temporaryRouteTrackingEndsAt else { return }
        let secondsUntilExpiry = endsAt.timeIntervalSinceNow
        guard secondsUntilExpiry > 0 else {
            expireTemporaryRouteTracking()
            return
        }

        let nanoseconds = UInt64((secondsUntilExpiry * 1_000_000_000).rounded())
        temporaryRouteTrackingExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            await MainActor.run {
                self?.expireTemporaryRouteTrackingIfStillCurrent(expectedEndDate: endsAt)
            }
        }
    }

    private func cancelTemporaryRouteTrackingExpiryTask() {
        temporaryRouteTrackingExpiryTask?.cancel()
        temporaryRouteTrackingExpiryTask = nil
    }

    private func persistTemporaryRouteTrackingState() {
        userDefaults.set(temporaryRouteTrackingDuration.rawValue, forKey: TemporaryRouteTrackingStorageKey.duration)
        if let temporaryRouteTrackingStartedAt {
            userDefaults.set(temporaryRouteTrackingStartedAt, forKey: TemporaryRouteTrackingStorageKey.startedAt)
        } else {
            userDefaults.removeObject(forKey: TemporaryRouteTrackingStorageKey.startedAt)
        }
        userDefaults.set(
            temporaryRouteTrackingStopsAtFiftyPercentBattery,
            forKey: TemporaryRouteTrackingStorageKey.stopAtFiftyPercentBattery
        )
        userDefaults.set(
            temporaryRouteTrackingStopsInLowPowerMode,
            forKey: TemporaryRouteTrackingStorageKey.stopInLowPowerMode
        )
        userDefaults.set(
            temporaryRouteTrackingStopNotificationEnabled,
            forKey: TemporaryRouteTrackingStorageKey.stopNotificationEnabled
        )

        if let temporaryRouteTrackingEndsAt {
            userDefaults.set(temporaryRouteTrackingEndsAt, forKey: TemporaryRouteTrackingStorageKey.endsAt)
        } else {
            userDefaults.removeObject(forKey: TemporaryRouteTrackingStorageKey.endsAt)
        }
    }

    private func expireTemporaryRouteTracking() {
        expireTemporaryRouteTracking(notifyImmediately: false)
    }

    private func expireTemporaryRouteTracking(notifyImmediately: Bool) {
        cancelTemporaryRouteTrackingExpiryTask()
        temporaryRouteTrackingStartedAt = nil
        temporaryRouteTrackingEndsAt = nil
        persistTemporaryRouteTrackingState()
        if notifyImmediately {
            notifyTemporaryRouteTrackingStoppedImmediatelyIfNeeded()
        }
        applyTrackingConfiguration()
        Task {
            await routeTrackingLiveActivity.end()
        }
    }

    private func expireTemporaryRouteTrackingIfStillCurrent(expectedEndDate: Date) {
        guard temporaryRouteTrackingEndsAt == expectedEndDate else { return }
        guard expectedEndDate <= .now else { return }
        expireTemporaryRouteTracking()
    }

    private var shouldExpireTemporaryRouteTrackingNow: Bool {
        if temporaryRouteTrackingStopsInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled {
            return true
        }

        if temporaryRouteTrackingStopsAtFiftyPercentBattery {
            let batteryLevel = UIDevice.current.batteryLevel
            if batteryLevel >= 0 && batteryLevel <= 0.5 {
                return true
            }
        }

        return false
    }

    private func installTemporaryRouteTrackingEnergyObservers() {
        let center = NotificationCenter.default

        temporaryRouteTrackingEnergyStateObserverTokens.append(
            center.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshTemporaryRouteTrackingStateIfNeeded()
                }
            }
        )
        temporaryRouteTrackingEnergyStateObserverTokens.append(
            center.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshTemporaryRouteTrackingStateIfNeeded()
                }
            }
        )
        temporaryRouteTrackingEnergyStateObserverTokens.append(
            center.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshTemporaryRouteTrackingStateIfNeeded()
                }
            }
        )
    }

    private func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func requestNotificationAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func scheduleTemporaryRouteTrackingStoppedNotificationIfNeeded() {
        guard temporaryRouteTrackingStopNotificationEnabled else { return }
        guard let endsAt = temporaryRouteTrackingEndsAt, endsAt > .now else { return }

        Task { @MainActor in
            guard temporaryRouteTrackingStopNotificationEnabled,
                  temporaryRouteTrackingEndsAt == endsAt else {
                return
            }

            let authorizationStatus = await notificationAuthorizationStatus()
            guard authorizationStatus == .authorized ||
                authorizationStatus == .provisional ||
                authorizationStatus == .ephemeral else {
                cancelTemporaryRouteTrackingStoppedNotification()
                return
            }

            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "Real route tracking stopped"
            content.body = "Moves switched back to lower-power tracking."
            content.sound = .default

            let interval = max(endsAt.timeIntervalSinceNow, 1)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.stopNotificationIdentifier,
                content: content,
                trigger: trigger
            )

            center.removePendingNotificationRequests(withIdentifiers: [Self.stopNotificationIdentifier])
            center.add(request) { _ in }
        }
    }

    private func cancelTemporaryRouteTrackingStoppedNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.stopNotificationIdentifier]
        )
    }

    private func notifyTemporaryRouteTrackingStoppedImmediatelyIfNeeded() {
        guard temporaryRouteTrackingStopNotificationEnabled else { return }

        Task { @MainActor in
            cancelTemporaryRouteTrackingStoppedNotification()

            guard temporaryRouteTrackingStopNotificationEnabled else { return }

            let authorizationStatus = await notificationAuthorizationStatus()
            guard authorizationStatus == .authorized ||
                authorizationStatus == .provisional ||
                authorizationStatus == .ephemeral else {
                return
            }

            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "Real route tracking stopped"
            content.body = "Moves switched back to lower-power tracking."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: Self.stopNotificationIdentifier,
                content: content,
                trigger: nil
            )

            center.removePendingNotificationRequests(withIdentifiers: [Self.stopNotificationIdentifier])
            center.add(request) { _ in }
        }
    }
}

extension MovesLocationCaptureManager: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard isBackgroundLocationListeningEnabled else { return }

        refreshTemporaryRouteTrackingStateIfNeeded()

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

        refreshTemporaryRouteTrackingStateIfNeeded()

        guard pendingOneShotLocationSource != nil
            || isTemporaryRouteTrackingActive
            || isBackgroundLocationListeningEnabled
        else { return }

        lastCaptureAt = .now
        let source: LocationSampleSource = pendingOneShotLocationSource ?? (isTemporaryRouteTrackingActive ? .routeTracking : .significantChange)
        pendingOneShotLocationSource = nil

        Task {
            if source == .routeTracking {
                await routeTrackingLiveActivity.record(
                    locations,
                    endsAt: temporaryRouteTrackingEndsAt
                )
            }
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
