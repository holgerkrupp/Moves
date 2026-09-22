import SwiftData
import SwiftUI

@main
struct MovesMacApp: App {
    private static let cloudKitContainerIdentifier = "iCloud.de.holgerkrupp.Moves"
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try Self.makeModelContainer()
        } catch {
            fatalError("Could not create the Moves macOS model container: \(error)")
        }
    }

    static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            KnownLocation.self,
            MoveSegment.self,
            LocationSample.self,
            MovesDeviceProfile.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(cloudKitContainerIdentifier)
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    var body: some Scene {
        WindowGroup("Moves") {
            MovesMacTimelineView()
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 900, height: 650)
    }
}

private struct MovesMacTimelineView: View {
    @Query(sort: \DayTimeline.dayStart, order: .reverse)
    private var timelines: [DayTimeline]
    @State private var selectedDayKey: String?

    var body: some View {
        NavigationSplitView {
            List(timelines, selection: $selectedDayKey) { timeline in
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeline.dayStart, format: .dateTime.year().month().day())
                        .font(.headline)
                    Text(summary(for: timeline))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(timeline.dayKey)
            }
            .navigationTitle("Timeline")
        } detail: {
            if let selectedDayKey,
               let timeline = timelines.first(where: { $0.dayKey == selectedDayKey }) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(timeline.dayStart, format: .dateTime.year().month().day())
                        .font(.largeTitle.bold())
                    LabeledContent("Places", value: timeline.places.count.formatted())
                    LabeledContent("Moves", value: timeline.moves.count.formatted())
                    LabeledContent("Location samples", value: timeline.samples.count.formatted())
                    Spacer()
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    "Select a day",
                    systemImage: "calendar",
                    description: Text("Moves reads the timeline shared through your private iCloud container.")
                )
            }
        }
    }

    private func summary(for timeline: DayTimeline) -> String {
        let places = timeline.places.count
        let moves = timeline.moves.count
        let samples = timeline.samples.count
        return "\(places) places · \(moves) moves · \(samples) samples"
    }
}
