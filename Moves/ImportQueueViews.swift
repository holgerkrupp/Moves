import SwiftUI

struct ImportCircularProgressView: View {
    let progress: Double?
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.22), lineWidth: 2.5)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else if isActive {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .accessibilityLabel("Import progress")
        .accessibilityValue(progress.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "In progress")
    }
}

struct ImportQueueToolbarButton: View {
    @ObservedObject var coordinator: ImportCoordinator
    @Binding var isPresented: Bool

    var body: some View {
        Button { isPresented = true } label: {
            ImportCircularProgressView(
                progress: coordinator.snapshot.aggregateProgress,
                isActive: !coordinator.snapshot.unfinishedJobs.isEmpty
            )
                .frame(width: 22, height: 22)
                .overlay {
                    if coordinator.snapshot.unfinishedJobs.isEmpty {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
        }
        .accessibilityLabel("Import queue")
        .accessibilityValue(queueAccessibilityValue)
        .help("Import queue")
    }

    private var queueAccessibilityValue: String {
        let count = coordinator.snapshot.unfinishedJobs.count
        guard count > 0 else { return "No active imports" }
        if let progress = coordinator.snapshot.aggregateProgress {
            return "\(count) active import\(count == 1 ? "" : "s"), \(progress.formatted(.percent.precision(.fractionLength(0))))"
        }
        return "\(count) active import\(count == 1 ? "" : "s")"
    }
}

struct ImportQueueView: View {
    @ObservedObject var coordinator: ImportCoordinator
    var onResume: ((UUID) -> Void)?
    var onPause: ((UUID) -> Void)?
    var onCancel: ((UUID) -> Void)?
    @State private var isShowingImportOptions = false
    @State private var isShowingFileImporter = false
    @State private var importConfiguration = RouteFileImportConfiguration()

    var body: some View {
        NavigationStack {
            List {
                if coordinator.snapshot.jobs.isEmpty {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "No imports",
                            systemImage: "tray",
                            description: Text("Route files you import will appear here.")
                        )
                        Button("Import file", systemImage: "square.and.arrow.down") {
                            isShowingImportOptions = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    if let progress = coordinator.snapshot.aggregateProgress {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Overall progress").font(.headline)
                                    Spacer()
                                    Text(progress, format: .percent.precision(.fractionLength(0)))
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: progress)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    ForEach(coordinator.snapshot.jobs) { job in
                        ImportQueueJobRow(
                            job: job,
                            pause: {
                                try? coordinator.pause(id: job.id)
                                onPause?(job.id)
                            },
                            resume: {
                                try? coordinator.resume(id: job.id)
                                onResume?(job.id)
                            },
                            cancel: {
                                try? coordinator.cancel(id: job.id)
                                onCancel?(job.id)
                            },
                            retry: {
                                try? coordinator.retry(id: job.id)
                                onResume?(job.id)
                            }
                        )
                    }
                }

                if !coordinator.recoveryItems.isEmpty {
                    Section("Needs attention") {
                        ForEach(coordinator.recoveryItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(item.displayName, systemImage: item.kind == .needsInformation ? "questionmark.circle" : "exclamationmark.triangle")
                                    Spacer()
                                    Button("Discard", role: .destructive) {
                                        try? coordinator.removeRecovery(id: item.id)
                                    }
                                    .font(.caption)
                                }
                                Text(item.kind == .needsInformation ? "Needs information" : "Import failed")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(item.kind == .needsInformation ? .orange : .red)
                                Text(item.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("Import Queue")
            .toolbar {
                if !coordinator.snapshot.jobs.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import file", systemImage: "square.and.arrow.down") {
                            isShowingImportOptions = true
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingImportOptions) {
                RouteFileImportOptionsView(configuration: $importConfiguration) {
                    isShowingImportOptions = false
                    Task { @MainActor in
                        await Task.yield()
                        isShowingFileImporter = true
                    }
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: RouteFileImportContentTypes.allowed,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    coordinator.enqueueRouteFiles(urls, configuration: importConfiguration)
                }
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
}

private struct ImportQueueJobRow: View {
    let job: ImportJobRecord
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ImportCircularProgressView(
                    progress: job.counters.progress,
                    isActive: ![.completed, .cancelled].contains(job.state)
                )
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.displayName).font(.headline)
                        .lineLimit(2)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(job.state == .failed ? .red : .secondary)
                    if let error = job.lastError {
                        Text(error.message).font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
                menu
            }
            if let progress = job.counters.progress {
                ProgressView(value: progress)
                    .accessibilityLabel("Progress for (job.displayName)")
            }
            if hasCounters {
                Text(counterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Import (job.displayName)")
        .accessibilityValue(statusText + (hasCounters ? ", " + counterText : ""))
    }

    @ViewBuilder private var menu: some View {
        Menu {
            switch job.state {
            case .acquiring, .parsing, .importing, .postProcessing:
                Button("Pause", systemImage: "pause.fill", action: pause)
            case .paused, .queued:
                Button("Resume", systemImage: "play.fill", action: resume)
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
            default:
                EmptyView()
            }
            if ![.completed, .cancelled].contains(job.state) {
                Button("Cancel", systemImage: "xmark", role: .destructive, action: cancel)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Actions for (job.displayName)")
    }

    private var statusText: String {
        if let phase = job.phase { return phase.title }
        switch job.state {
        case .queued: return "Queued"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .needsInformation: return "Needs information"
        default: return job.state.rawValue.capitalized
        }
    }

    private var hasCounters: Bool {
        job.counters.itemCount > 0 || job.counters.routeCount > 0 || job.counters.sampleCount > 0
    }

    private var counterText: String {
        var values = [String]()
        if job.counters.itemCount > 0 { values.append("\(job.counters.completedItemCount)/\(job.counters.itemCount) files") }
        if job.counters.routeCount > 0 { values.append("\(job.counters.routeCount) routes") }
        if job.counters.sampleCount > 0 { values.append("\(job.counters.sampleCount) points") }
        return values.joined(separator: " · ")
    }
}

private extension ImportJobPhase {
    var title: String {
        switch self {
        case .acquiring: "Preparing files"
        case .parsing: "Parsing routes"
        case .importing: "Importing route data"
        case .postProcessing: "Finishing import"
        }
    }
}

#Preview("Import queue") {
    let coordinator = ImportCoordinator(store: ImportQueueStore(fileURL: URL(fileURLWithPath: "/tmp/moves-preview-queue.json")))
    ImportQueueView(coordinator: coordinator)
        .frame(width: 420, height: 520)
}
