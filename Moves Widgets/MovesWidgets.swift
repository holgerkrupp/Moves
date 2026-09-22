import AppIntents
import SwiftUI
import WidgetKit

@main
struct MovesWidgets: WidgetBundle {
    var body: some Widget {
        MovesTodayWidget()
        #if !targetEnvironment(macCatalyst)
        MovesRouteTrackingLiveActivityWidget()
        #endif
    }
}

struct MovesTodayConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Configure Moves Today"
    static let description = IntentDescription("Choose how much transport detail the widget shows.")

    @Parameter(title: "Show transport breakdown", default: true)
    var showsTransportBreakdown: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Show transport breakdown: \(\.$showsTransportBreakdown)")
    }
}

struct MovesAppIntentWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MovesWidgetEntry {
        MovesWidgetEntry(date: .now, snapshot: .placeholder)
    }

    func snapshot(
        for configuration: MovesTodayConfigurationIntent,
        in context: Context
    ) async -> MovesWidgetEntry {
        MovesWidgetEntry(
            date: .now,
            snapshot: TimelineWidgetSnapshotStore.load(),
            showsTransportBreakdown: configuration.showsTransportBreakdown
        )
    }

    func timeline(
        for configuration: MovesTodayConfigurationIntent,
        in context: Context
    ) async -> Timeline<MovesWidgetEntry> {
        let entry = MovesWidgetEntry(
            date: .now,
            snapshot: TimelineWidgetSnapshotStore.load(),
            showsTransportBreakdown: configuration.showsTransportBreakdown
        )
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 20, to: .now)
            ?? .now.addingTimeInterval(20 * 60)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }
}

struct MovesTodayWidget: Widget {
    let kind = "MovesTodayWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: MovesTodayConfigurationIntent.self,
            provider: MovesAppIntentWidgetProvider()
        ) { entry in
            MovesWidgetRootView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "moves://today"))
        }
        .configurationDisplayName("Moves Today")
        .description("Shows today’s move distance, transport split, and visited locations.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .systemExtraLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
