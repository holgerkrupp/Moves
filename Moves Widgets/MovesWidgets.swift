import SwiftUI
import WidgetKit

@main
struct MovesWidgets: WidgetBundle {
    var body: some Widget {
        MovesTodayWidget()
        
    }
}

struct MovesTodayWidget: Widget {
    let kind = "MovesTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MovesWidgetProvider()) { entry in
            MovesWidgetRootView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
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
