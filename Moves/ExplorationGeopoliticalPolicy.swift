import Foundation

enum ExplorationContinent: String, Codable, CaseIterable, Sendable {
    case africa = "Africa"
    case asia = "Asia"
    case europe = "Europe"
    case northAmerica = "North America"
    case southAmerica = "South America"
    case oceania = "Oceania"
    case antarctica = "Antarctica"
    case other = "Other"
}

/// Product policy, deliberately separate from the raster and boundary files.
/// Boundary updates can therefore change display grouping without changing any
/// canonical cell or shard address.
enum ExplorationGeopoliticalPolicy {
    /// ISO 3166-1 codes representing dependencies, overseas territories,
    /// special areas, or disputed entities in the bundled Natural Earth data.
    /// The set is intentionally conservative: unknown codes are classified as
    /// broader entities rather than silently claimed as UN members.
    private static let broaderEntityCodes: Set<String> = [
        "AQ", "AS", "AW", "AX", "BM", "BQ", "BV", "CC", "CK", "CW", "CX",
        "EH", "FK", "FO", "GF", "GG", "GI", "GL", "GP", "GS", "GU", "HK", "HM",
        "IM", "IO", "JE", "KY", "MF", "MO", "MP", "MQ", "MS", "NC", "NF", "NU",
        "PF", "PM", "PN", "PR", "RE", "SH", "SJ", "SX", "TC", "TF", "TK", "UM",
        "VA", "VG", "VI", "WF", "YT", "XK", "XC", "-99"
    ]

    private static let continentCodes: [ExplorationContinent: Set<String>] = [
        .africa: [
            "DZ", "AO", "BJ", "BW", "BF", "BI", "CM", "CV", "CF", "TD", "KM", "CG", "CD",
            "CI", "DJ", "EG", "GQ", "ER", "SZ", "ET", "GA", "GM", "GH", "GN", "GW", "KE", "LS",
            "LR", "LY", "MG", "MW", "ML", "MR", "MU", "MA", "MZ", "NA", "NE", "NG", "RW", "ST",
            "SN", "SC", "SL", "SO", "ZA", "SS", "SD", "TZ", "TG", "TN", "UG", "ZM", "ZW"
        ],
        .asia: [
            "AF", "AM", "AZ", "BH", "BD", "BT", "BN", "KH", "CN", "CY", "GE", "IN", "ID", "IR",
            "IQ", "IL", "JP", "JO", "KZ", "KW", "KG", "LA", "LB", "MY", "MV", "MN", "MM", "NP",
            "KP", "OM", "PK", "PS", "PH", "QA", "SA", "SG", "KR", "LK", "SY", "TJ", "TH", "TL",
            "TR", "TM", "AE", "UZ", "VN", "YE"
        ],
        .europe: [
            "AL", "AD", "AT", "BY", "BE", "BA", "BG", "HR", "CZ", "DK", "EE", "FI", "FR", "DE",
            "GR", "HU", "IS", "IE", "IT", "LV", "LI", "LT", "LU", "MT", "MD", "MC", "ME", "NL",
            "MK", "NO", "PL", "PT", "RO", "RU", "SM", "RS", "SK", "SI", "ES", "SE", "CH", "UA",
            "GB", "VA", "XK"
        ],
        .northAmerica: [
            "AG", "BS", "BB", "BZ", "CA", "CR", "CU", "DM", "DO", "SV", "GD", "GT", "HT", "HN",
            "JM", "MX", "NI", "PA", "KN", "LC", "VC", "TT", "US"
        ],
        .southAmerica: [
            "AR", "BO", "BR", "CL", "CO", "EC", "GY", "PY", "PE", "SR", "UY", "VE"
        ],
        .oceania: ["AU", "FJ", "KI", "MH", "FM", "NR", "NZ", "PW", "PG", "WS", "SB", "TO", "TV", "VU"],
        .antarctica: ["AQ"]
    ]

    private static let knownCountryCodes: Set<String> = Set(continentCodes.values.joined())

    static func isUNMember(countryID: String) -> Bool {
        let normalized = countryID.uppercased()
        guard normalized.count == 2, normalized.allSatisfy(\.isLetter) else { return false }
        return knownCountryCodes.contains(normalized) && !broaderEntityCodes.contains(normalized)
    }

    static func continent(for countryID: String) -> ExplorationContinent {
        let normalized = countryID.uppercased()
        return continentCodes.first(where: { $0.value.contains(normalized) })?.key ?? .other
    }

    static func isBroaderEntity(countryID: String) -> Bool {
        !isUNMember(countryID: countryID)
    }
}
