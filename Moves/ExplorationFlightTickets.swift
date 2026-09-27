import CoreLocation
import Foundation
import SwiftUI

struct ExplorationFlightEndpoint: Codable, Equatable, Sendable {
    let placeName: String?
    let countryID: String?
    let countryName: String?
}

struct ExplorationFlightFacts: Codable, Equatable, Sendable {
    let moveID: UUID
    let departureDate: Date
    let arrivalDate: Date
    let origin: ExplorationFlightEndpoint
    let destination: ExplorationFlightEndpoint
    let distanceMeters: Double?
}

struct ExplorationFlightTicketRecipe: Codable, Equatable, Sendable {
    enum Family: String, Codable, Sendable { case paper, stub, modern, retro }
    enum Border: String, Codable, Sendable { case solid, dashed, perforated }

    static let generatorVersion = 1
    let generatorVersion: Int
    let family: Family
    let border: Border
    let inkRed: Double
    let inkGreen: Double
    let inkBlue: Double
    let rotationDegrees: Double
    let wear: Double
    let decorativeSerial: String
}

struct ExplorationFlightTicket: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let facts: ExplorationFlightFacts
    let recipe: ExplorationFlightTicketRecipe

    var duration: TimeInterval {
        max(0, facts.arrivalDate.timeIntervalSince(facts.departureDate))
    }
}

enum ExplorationFlightTicketGenerator {
    static func make(from facts: ExplorationFlightFacts) -> ExplorationFlightTicket {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Data("flight-ticket-v\(ExplorationFlightTicketRecipe.generatorVersion)#\(facts.moveID.uuidString)#\(facts.departureDate.timeIntervalSince1970.bitPattern)#\(facts.origin.countryID ?? "")#\(facts.destination.countryID ?? "")".utf8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        func next(_ bound: UInt64) -> UInt64 {
            hash = hash &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return hash % bound
        }
        let colors: [(Double, Double, Double)] = [
            (0.08, 0.24, 0.42), (0.44, 0.16, 0.22), (0.18, 0.36, 0.30), (0.50, 0.29, 0.08)
        ]
        let color = colors[Int(next(UInt64(colors.count)))]
        let serial = String(format: "MV-%06llX", next(0xFF_FFFF))
        let recipe = ExplorationFlightTicketRecipe(
            generatorVersion: ExplorationFlightTicketRecipe.generatorVersion,
            family: [.paper, .stub, .modern, .retro][Int(next(4))],
            border: [.solid, .dashed, .perforated][Int(next(3))],
            inkRed: color.0,
            inkGreen: color.1,
            inkBlue: color.2,
            rotationDegrees: Double(Int(next(7)) - 3),
            wear: Double(next(18)) / 100,
            decorativeSerial: serial
        )
        return ExplorationFlightTicket(id: facts.moveID, facts: facts, recipe: recipe)
    }
}

#if DEBUG
struct ExplorationFlightTicketDebugView: View {
    let segment: MoveSegment
    let routeCoordinates: [CLLocationCoordinate2D]
    @State private var ticket: ExplorationFlightTicket?

    var body: some View {
        Group {
            if let ticket {
                ExplorationFlightTicketCard(ticket: ticket)
                    .padding()
            } else {
                ProgressView("Preparing ticket…")
            }
        }
        .navigationTitle("Flight Ticket")
#if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task { await buildTicket() }
    }

    private func buildTicket() async {
        guard segment.transportMode == .plane else { return }
        let first = routeCoordinates.first
        let last = routeCoordinates.last
        let resolver = try? await Task.detached(priority: .utility) {
            try ExplorationCountryResolver.bundled()
        }.value
        let startCountry = first.flatMap { resolver?.country(at: $0) }
        let endCountry = last.flatMap { resolver?.country(at: $0) }
        let facts = ExplorationFlightFacts(
            moveID: segment.id,
            departureDate: segment.timelineStartDate,
            arrivalDate: segment.endDate,
            origin: ExplorationFlightEndpoint(
                placeName: segment.startPlace?.displayTitle,
                countryID: startCountry?.id,
                countryName: startCountry?.name
            ),
            destination: ExplorationFlightEndpoint(
                placeName: segment.endPlace?.displayTitle,
                countryID: endCountry?.id,
                countryName: endCountry?.name
            ),
            distanceMeters: segment.distanceMeters.isFinite ? segment.distanceMeters : nil
        )
        ticket = ExplorationFlightTicketGenerator.make(from: facts)
    }
}

private struct ExplorationFlightTicketCard: View {
    let ticket: ExplorationFlightTicket

    var body: some View {
        let recipe = ticket.recipe
        let ink = Color(red: recipe.inkRed, green: recipe.inkGreen, blue: recipe.inkBlue)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Moves Flight Keepsake", systemImage: "airplane")
                    .font(.headline)
                Spacer()
                Text(recipe.decorativeSerial)
                    .font(.caption2.monospaced())
            }
            HStack(alignment: .firstTextBaseline) {
                endpoint(ticket.facts.origin)
                Image(systemName: "arrow.right")
                    .foregroundStyle(ink)
                endpoint(ticket.facts.destination)
            }
            Divider()
            HStack {
                detail("Departure", ticket.facts.departureDate.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                detail("Duration", DurationFormatter.text(for: ticket.duration))
            }
            if let distance = ticket.facts.distanceMeters {
                detail("Recorded distance", Measurement(value: max(distance, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
            }
            Text("Decorative keepsake — not a boarding pass. No airline, airport, booking, gate, seat, barcode, or passenger data was invented.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .foregroundStyle(ink)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(ink.opacity(0.65), style: StrokeStyle(lineWidth: 2, dash: recipe.border == .dashed ? [6, 4] : []))
                }
        )
        .rotationEffect(.degrees(recipe.rotationDegrees))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func endpoint(_ value: ExplorationFlightEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.placeName ?? value.countryName ?? "Unknown")
                .font(.title3.weight(.bold))
                .lineLimit(2)
            if let countryName = value.countryName {
                Text(countryName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }

    private var accessibilityText: String {
        let origin = ticket.facts.origin.placeName ?? ticket.facts.origin.countryName ?? "unknown origin"
        let destination = ticket.facts.destination.placeName ?? ticket.facts.destination.countryName ?? "unknown destination"
        return "Flight keepsake from \(origin) to \(destination), \(ticket.facts.departureDate.formatted(date: .long, time: .shortened))"
    }
}
#endif
