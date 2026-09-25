import SwiftUI

struct MovesJumpToDateView: View {
    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case overall
        case placeCount
        case onFoot
        case swimming
        case cycling
        case automotive
        case motorcycle
        case train
        case plane
        case boat

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overall: return "Overall"
            case .placeCount: return "Places"
            case .onFoot: return "On Foot"
            case .swimming: return "Swim"
            case .cycling: return "Cycle"
            case .automotive: return "Car"
            case .motorcycle: return "Motorcycle"
            case .train: return "Train"
            case .plane: return "Plane"
            case .boat: return "Boat"
            }
        }

        var symbolName: String {
            switch self {
            case .overall: return "chart.bar.fill"
            case .placeCount: return "mappin.and.ellipse"
            case .onFoot: return "figure.walk"
            case .swimming: return "figure.pool.swim"
            case .cycling: return "figure.outdoor.cycle"
            case .automotive: return "car.fill"
            case .motorcycle: return "motorcycle.fill"
            case .train: return "tram.fill"
            case .plane: return "airplane"
            case .boat: return "sailboat.fill"
            }
        }

        var tint: Color {
            switch self {
            case .overall: return .secondary
            case .placeCount: return MovesPalette.place
            case .onFoot: return MovesPalette.transport(.running)
            case .swimming: return MovesPalette.transport(.swimming)
            case .cycling: return MovesPalette.transport(.cycling)
            case .automotive: return MovesPalette.transport(.automotive)
            case .motorcycle: return MovesPalette.transport(.motorcycle)
            case .train: return MovesPalette.transport(.train)
            case .plane: return MovesPalette.transport(.plane)
            case .boat: return MovesPalette.transport(.boat)
            }
        }
    }

    private let daySummaries: [TimelineDaySummary]
    private let onSelectDate: (Date) -> Void
    private let onDismiss: () -> Void

    @State private var pickerDate: Date
    @State private var activityFilter: ActivityFilter = .overall

    init(
        daySummaries: [String: TimelineDaySummary],
        selectedDate: Date,
        onSelectDate: @escaping (Date) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.daySummaries = daySummaries.values
            .filter { $0.dayStart != .distantPast }
            .sorted { $0.dayStart < $1.dayStart }
        self.onSelectDate = onSelectDate
        self.onDismiss = onDismiss
        _pickerDate = State(initialValue: selectedDate)
    }

    private var earliestRecordedDayStart: Date? {
        daySummaries.first?.dayStart
    }

    private var latestSelectableDayStart: Date {
        Calendar.autoupdatingCurrent.startOfDay(for: .now)
    }

    private var mostActiveDays: [TimelineDaySummary] {
        daySummaries
            .sorted { lhs, rhs in
                activityScore(for: lhs, filter: activityFilter) > activityScore(for: rhs, filter: activityFilter)
            }
            .filter { activityScore(for: $0, filter: activityFilter) > 0 }
            .prefix(5)
            .map { $0 }
    }

    private var availableActivityFilters: [ActivityFilter] {
        let transportFilters: [ActivityFilter] = [.onFoot, .swimming, .cycling, .automotive, .motorcycle, .train, .plane, .boat]
        let availableTransports = transportFilters.filter { totalDistance(for: $0) > 0 }
        return [.overall, .placeCount] + availableTransports
    }

    var body: some View {
        #if os(macOS)
        navigationContent
            .frame(width: 440, height: 620)
        #else
        navigationContent
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.large])
        #endif
    }

    private var navigationContent: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let earliestRecordedDayStart {
                        DatePicker(
                            "Date",
                            selection: $pickerDate,
                            in: earliestRecordedDayStart...latestSelectableDayStart,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .onChange(of: pickerDate) { _, newDate in
                            onSelectDate(newDate)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Earliest") {
                            guard let earliestRecordedDayStart else { return }
                            pickerDate = earliestRecordedDayStart
                            onSelectDate(earliestRecordedDayStart)
                            onDismiss()
                        }
                        .buttonStyle(.bordered)

                        Button("Today") {
                            pickerDate = latestSelectableDayStart
                            onSelectDate(latestSelectableDayStart)
                            onDismiss()
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("Most active days")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 8)

                            Menu {
                                ForEach(availableActivityFilters) { filter in
                                    Button {
                                        activityFilter = filter
                                    } label: {
                                        Label(filter.title, systemImage: filter.symbolName)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: activityFilter.symbolName)
                                        .foregroundStyle(activityFilter.tint)
                                    Text(activityFilter.title)
                                        .foregroundStyle(.primary)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(MovesPalette.card.opacity(0.8))
                                )
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize(horizontal: true, vertical: false)
                        }

                        if mostActiveDays.isEmpty {
                            Text("No matching days for this filter yet.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(Array(mostActiveDays.enumerated()), id: \.offset) { _, day in
                                Button {
                                    pickerDate = day.dayStart
                                    onSelectDate(day.dayStart)
                                    onDismiss()
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(day.dayStart, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        if day.hasImportedRouteData {
                                            Image(systemName: "tray.and.arrow.down.fill")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(MovesPalette.routeTracking)
                                                .accessibilityLabel("Contains imported data")
                                        }

                                        Spacer(minLength: 4)

                                        Text("\(day.uniquePlaceCount) places")
                                        Text("\(day.moveCount) moves")
                                        Text(Measurement(value: day.totalDistanceMeters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                                    }
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Jump to Date")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .onChange(of: availableActivityFilters) { _, filters in
            if !filters.contains(activityFilter) {
                activityFilter = .overall
            }
        }
    }

    private func activityScore(for day: TimelineDaySummary, filter: ActivityFilter) -> Double {
        switch filter {
        case .overall:
            return day.activityScore
        case .placeCount:
            return Double(day.uniquePlaceCount)
        case .onFoot:
            return filteredScore(for: day, bucket: "walking")
        case .swimming:
            return filteredScore(for: day, bucket: "swimming")
        case .cycling:
            return filteredScore(for: day, bucket: "cycling")
        case .automotive:
            return filteredScore(for: day, bucket: "automotive")
        case .motorcycle:
            return filteredScore(for: day, bucket: "motorcycle")
        case .train:
            return filteredScore(for: day, bucket: "train")
        case .plane:
            return filteredScore(for: day, bucket: "plane")
        case .boat:
            return filteredScore(for: day, bucket: "boat")
        }
    }

    private func filteredScore(for day: TimelineDaySummary, bucket: String) -> Double {
        day.transportDistanceMeters[bucket, default: 0]
            + day.transportDuration[bucket, default: 0] / 8
    }

    private func totalDistance(for filter: ActivityFilter) -> Double {
        guard let bucket = transportBucket(for: filter) else { return 0 }
        return daySummaries.reduce(0) { $0 + $1.transportDistanceMeters[bucket, default: 0] }
    }

    private func transportBucket(for filter: ActivityFilter) -> String? {
        switch filter {
        case .onFoot: return "walking"
        case .swimming: return "swimming"
        case .cycling: return "cycling"
        case .automotive: return "automotive"
        case .motorcycle: return "motorcycle"
        case .train: return "train"
        case .plane: return "plane"
        case .boat: return "boat"
        case .overall, .placeCount: return nil
        }
    }
}
