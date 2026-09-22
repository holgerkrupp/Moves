import CoreLocation
import Foundation

#if targetEnvironment(macCatalyst)
/// Live Activities are unavailable on Mac Catalyst. Keep the tracking call sites
/// platform-neutral while allowing the iOS implementation below to publish them.
@MainActor
final class RouteTrackingLiveActivityCoordinator {
    func synchronize(startedAt: Date?, endsAt: Date?) async {}
    func record(_ locations: [CLLocation], endsAt: Date?) async {}
    func end() async {}
}
#else
import ActivityKit

@MainActor
final class RouteTrackingLiveActivityCoordinator {
    private var lastLocation: CLLocation?
    private var distanceMeters: CLLocationDistance = 0
    private var sampleCount = 0
    private var lastPublishedAt: Date?

    func synchronize(startedAt: Date?, endsAt: Date?) async {
        guard let startedAt, let endsAt, endsAt > .now else {
            await end()
            return
        }

        let existing = Activity<MovesRouteTrackingAttributes>.activities.first
        if let existing,
           abs(existing.attributes.startedAt.timeIntervalSince(startedAt)) < 1 {
            distanceMeters = existing.content.state.distanceMeters
            sampleCount = existing.content.state.sampleCount
            await publish(on: existing, endsAt: endsAt)
            return
        }

        for activity in Activity<MovesRouteTrackingAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = MovesRouteTrackingAttributes.ContentState(
            endsAt: endsAt,
            distanceMeters: 0,
            sampleCount: 0,
            lastUpdatedAt: .now
        )
        let content = ActivityContent(state: state, staleDate: endsAt)

        do {
            _ = try Activity.request(
                attributes: MovesRouteTrackingAttributes(startedAt: startedAt),
                content: content,
                pushType: nil,
                style: .standard
            )
            lastPublishedAt = .now
        } catch {
            // Tracking remains functional if Live Activities are unavailable.
        }
    }

    func record(_ locations: [CLLocation], endsAt: Date?) async {
        guard let endsAt, endsAt > .now, !locations.isEmpty else { return }

        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let lastLocation {
                let segmentDistance = lastLocation.distance(from: location)
                if segmentDistance.isFinite, segmentDistance >= 0, segmentDistance < 5_000 {
                    distanceMeters += segmentDistance
                }
            }
            lastLocation = location
            sampleCount += 1
        }

        let now = Date.now
        guard lastPublishedAt.map({ now.timeIntervalSince($0) >= 15 }) ?? true else { return }
        guard let activity = Activity<MovesRouteTrackingAttributes>.activities.first else { return }
        await publish(on: activity, endsAt: endsAt)
    }

    func end() async {
        let finalState = Activity<MovesRouteTrackingAttributes>.activities.first.map {
            MovesRouteTrackingAttributes.ContentState(
                endsAt: min($0.content.state.endsAt, .now),
                distanceMeters: distanceMeters,
                sampleCount: sampleCount,
                lastUpdatedAt: .now
            )
        }
        let finalContent = finalState.map { ActivityContent(state: $0, staleDate: nil) }

        for activity in Activity<MovesRouteTrackingAttributes>.activities {
            await activity.end(finalContent, dismissalPolicy: .default)
        }

        lastLocation = nil
        distanceMeters = 0
        sampleCount = 0
        lastPublishedAt = nil
    }

    private func publish(
        on activity: Activity<MovesRouteTrackingAttributes>,
        endsAt: Date
    ) async {
        let state = MovesRouteTrackingAttributes.ContentState(
            endsAt: endsAt,
            distanceMeters: distanceMeters,
            sampleCount: sampleCount,
            lastUpdatedAt: .now
        )
        await activity.update(ActivityContent(state: state, staleDate: endsAt))
        lastPublishedAt = .now
    }
}
#endif
