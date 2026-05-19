import SwiftUI
import WidgetKit

@main
struct MovesWatchComplications: WidgetBundle {
    var body: some Widget {
        MovesWatchTodayComplication()
        MovesWatchLauncherComplication()
    }
}

struct MovesWatchTodayComplication: Widget {
    let kind = "MovesWatchTodayComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MovesWidgetProvider()) { entry in
            MovesWidgetRootView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Moves Today")
        .description("Shows move distance, transport distance, and visited locations.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}

struct MovesWatchLauncherComplication: Widget {
    let kind = "MovesWatchLauncherComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MovesWidgetProvider()) { entry in
            MovesLauncherView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Moves Launcher")
        .description("A compact launcher for opening Moves on Apple Watch.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
        

    }
}

struct MovesLauncherView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MovesWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "M")
                    .font(.title3.weight(.bold))
            }
            .widgetURL(URL(string: "moves://today"))
        case .accessoryRectangular:
            Label("Open Moves", image: "M")
                .widgetURL(URL(string: "moves://today"))
           
        case .accessoryInline:
            Text("Open Moves")
                .widgetURL(URL(string: "moves://today"))
        case .accessoryCorner:
            Image("M")
                .widgetCurvesContent()
                .widgetURL(URL(string: "moves://today"))
                
        default:
            MovesCircularAccessory(snapshot: entry.snapshot)
        }
    }
}

#if DEBUG
#Preview("Launcher Circular") {
    MovesLauncherView(entry: MovesWidgetEntry(date: .now, snapshot: .placeholder))
        .previewContext(WidgetPreviewContext(family: .accessoryCircular))
}

#Preview("Launcher Rectangular") {
    MovesLauncherView(entry: MovesWidgetEntry(date: .now, snapshot: .placeholder))
        .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
}

#Preview("Launcher Inline") {
    MovesLauncherView(entry: MovesWidgetEntry(date: .now, snapshot: .placeholder))
        .previewContext(WidgetPreviewContext(family: .accessoryInline))
}
#endif
