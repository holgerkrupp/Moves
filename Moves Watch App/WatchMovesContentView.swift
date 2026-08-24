import SwiftUI
import MapKit

struct WatchMovesContentView: View {
    @EnvironmentObject private var tracker: WatchLocationTracker

    @State private var camera: MapCameraPosition = .automatic

    private var totalDistanceText: String {
        Measurement(value: tracker.daySummary.totalDistanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var liveCoordinate: CLLocationCoordinate2D? {
        tracker.isTracking ? tracker.todayRouteCoordinates.last : nil
    }

    private var mapRegion: MKCoordinateRegion {
        let coordinates = tracker.todayRouteCoordinates
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06)
            )
        }

        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let latitudeDelta = max((maxLatitude - minLatitude) * 1.35, 0.01)
        let longitudeDelta = max((maxLongitude - minLongitude) * 1.35, 0.01)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if tracker.todayRouteCoordinates.count > 1 {
                    MapPolyline(coordinates: tracker.todayRouteCoordinates)
                        .stroke(Color("MovesRouteTracking"), lineWidth: 4)
                }
                if let liveCoordinate {
                    Annotation("Current location", coordinate: liveCoordinate) {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(0.28))
                                .frame(width: 20, height: 20)
                            Circle()
                                .fill(Color("MovesRouteTracking"))
                                .frame(width: 10, height: 10)
                        }
                    }
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Button {
                        tracker.toggleTracking()
                    } label: {
                        Label(
                            tracker.isTracking ? "Stop GPS" : "Start GPS",
                            systemImage: tracker.isTracking ? "location.viewfinder" : "location.fill.viewfinder"
                        )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .frame(width: 40, height: 40)
                    }
                    .padding(8)
                    .buttonStyle(.plain)
                    .tint(tracker.isTracking ? .red : Color("MovesRouteTracking"))
                    .background(tracker.isTracking ? Color.red : Color("MovesRouteTracking"), in: Circle())
                    .foregroundStyle(.white)
                    .accessibilityLabel(tracker.isTracking ? "Stop GPS" : "Start GPS")

                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tracker.daySummary.dayTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(tracker.statusText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    VStack {
                        HStack {
                            Text(totalDistanceText)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Spacer(minLength: 8)
                            Text("\(tracker.daySummary.visitedLocationCount) places")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        Text("\(tracker.daySummary.moveCount) moves today")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(8)
        }
        .ignoresSafeArea()
        .task {
            tracker.startFallbackMonitoring()
            tracker.flushStoredRoutes()
        }
        .onAppear {
            camera = .region(mapRegion)
        }
        .onChange(of: tracker.todayRouteCoordinates.count) { _, _ in
            camera = .region(mapRegion)
        }
    }
}

