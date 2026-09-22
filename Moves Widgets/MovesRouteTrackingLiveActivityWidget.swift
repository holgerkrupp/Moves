#if !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit

struct MovesRouteTrackingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MovesRouteTrackingAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "location.fill")
                    .font(.title2)
                    .foregroundStyle(.teal)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Real route tracking")
                        .font(.headline)
                    Text(timerInterval: context.attributes.startedAt...context.state.endsAt, countsDown: false)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(distanceText(context.state.distanceMeters))
                        .font(.headline.monospacedDigit())
                    Text("until \(context.state.endsAt, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(Color(.systemBackground))
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(URL(string: "moves://tracking"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Moves", systemImage: "location.fill")
                        .foregroundStyle(.teal)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(distanceText(context.state.distanceMeters))
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("Real route tracking")
                        Spacer()
                        Text(timerInterval: Date.now...context.state.endsAt, countsDown: true)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "location.fill")
                    .foregroundStyle(.teal)
            } compactTrailing: {
                Text(distanceText(context.state.distanceMeters))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "location.fill")
                    .foregroundStyle(.teal)
            }
            .widgetURL(URL(string: "moves://tracking"))
            .keylineTint(.teal)
        }
    }
}
#endif
