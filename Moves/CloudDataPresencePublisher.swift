import CloudDataPresence
import Foundation
import SwiftData

@MainActor
final class MovesCloudDataPresencePublisher: ObservableObject {
    private enum PresenceKeys {
        static let moves = "cloudPresence.moves.v1"
        static let places = "cloudPresence.places.v1"
    }

    private let modelContainer: ModelContainer
    private var pendingPublishTask: Task<Void, Never>?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func publishNow() async {
        pendingPublishTask?.cancel()
        await publishCurrentCounts()
    }

    func publishSoon() {
        pendingPublishTask?.cancel()
        pendingPublishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await self?.publishCurrentCounts()
        }
    }

    private func publishCurrentCounts() async {
        let context = ModelContext(modelContainer)

        do {
            let placeCount = try context.fetchCount(FetchDescriptor<VisitPlace>())
            let moveCount = try context.fetchCount(FetchDescriptor<MoveSegment>())

            CloudDataPresenceStore.publish(
                recordCountsByKey: [
                    PresenceKeys.places: placeCount,
                    PresenceKeys.moves: moveCount,
                ]
            )
        } catch {
            print("Failed to publish CloudDataPresence counts: \(error.localizedDescription)")
        }
    }
}
