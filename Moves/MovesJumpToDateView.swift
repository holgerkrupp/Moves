import CoreLocation
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

    private let dayTimelines: [DayTimeline]
    private let onSelectDate: (Date) -> Void
    private let onDismiss: () -> Void

    @State private var pickerDate: Date
    @State private var activityFilter: ActivityFilter = .overall

    init(
        dayTimelines: [DayTimeline],
        selectedDate: Date,
        onSelectDate: @escaping (Date) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.dayTimelines = dayTimelines
        self.onSelectDate = onSelectDate
        self.onDismiss = onDismiss
        _pickerDate = State(initialValue: selectedDate)
    }

    private var earliestRecordedDayStart: Date? {
        dayTimelines.first?.dayStart
    }

    private var latestSelectableDayStart: Date {
        Calendar.autoupdatingCurrent.startOfDay(for: .now)
    }

    private var mostActiveDays: [DayTimeline] {
        dayTimelines
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
                            ForEach(mostActiveDays, id: \.dayKey) { day in
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

                                        Text("\(day.uniqueLocationCount) places")
                                        Text("\(day.moves.count) moves")
                                        Text(Measurement(value: totalDistance(for: day), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .presentationDetents([.large])
        .onChange(of: availableActivityFilters) { _, filters in
            if !filters.contains(activityFilter) {
                activityFilter = .overall
            }
        }
    }

    private func activityScore(for day: DayTimeline, filter: ActivityFilter) -> Double {
        let totalDistance = day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
        let totalMoveDuration = day.moves.reduce(0) { $0 + max($1.timelineDuration, 0) }
        let filteredMoves: [MoveSegment]

        switch filter {
        case .overall:
            filteredMoves = day.moves
        case .placeCount:
            return Double(day.uniqueLocationCount)
        case .onFoot:
            filteredMoves = day.moves.filter { $0.transportMode == .walking || $0.transportMode == .running }
        case .swimming:
            filteredMoves = day.moves.filter { $0.transportMode == .swimming }
        case .cycling:
            filteredMoves = day.moves.filter { $0.transportMode == .cycling }
        case .automotive:
            filteredMoves = day.moves.filter { $0.transportMode == .automotive }
        case .motorcycle:
            filteredMoves = day.moves.filter { $0.transportMode == .motorcycle }
        case .train:
            filteredMoves = day.moves.filter { $0.transportMode == .train }
        case .plane:
            filteredMoves = day.moves.filter { $0.transportMode == .plane }
        case .boat:
            filteredMoves = day.moves.filter { $0.transportMode == .boat }
        }

        if filter == .overall {
            let placeComponent = Double(day.uniqueLocationCount) * 1_200
            let moveComponent = Double(day.moves.count) * 900
            return placeComponent + moveComponent + totalDistance + totalMoveDuration / 8
        }

        let filteredDistance = filteredMoves.reduce(0) { $0 + max($1.distanceMeters, 0) }
        let filteredDuration = filteredMoves.reduce(0) { $0 + max($1.timelineDuration, 0) }
        return filteredDistance + filteredDuration / 8
    }

    private func totalDistance(for day: DayTimeline) -> CLLocationDistance {
        day.moves.reduce(0) { $0 + max($1.distanceMeters, 0) }
    }

    private func totalDistance(for filter: ActivityFilter) -> CLLocationDistance {
        dayTimelines.reduce(0) { partial, day in
            partial + day.moves.reduce(0) { moveTotal, move in
                let matches: Bool
                switch filter {
                case .onFoot:
                    matches = move.transportMode == .walking || move.transportMode == .running
                case .swimming:
                    matches = move.transportMode == .swimming
                case .cycling:
                    matches = move.transportMode == .cycling
                case .automotive:
                    matches = move.transportMode == .automotive
                case .motorcycle:
                    matches = move.transportMode == .motorcycle
                case .train:
                    matches = move.transportMode == .train
                case .plane:
                    matches = move.transportMode == .plane
                case .boat:
                    matches = move.transportMode == .boat
                case .overall, .placeCount:
                    matches = false
                }
                return moveTotal + (matches ? max(move.distanceMeters, 0) : 0)
            }
        }
    }
}
