import Foundation
import CoreLocation
import MapKit

struct ContextClassifier {
    struct Profile {
        let effectiveRadius: CLLocationDistance

        let specificity: Double // How specific this context is, a higher specificity means it's less common and should be weighted more heavily in the scoring algorithm
        let debt: Double // Baseline "debt" for this context. Runtime debt accumulates on top of this (see ContextDetector.debts) the longer a context has been active while traveling, so less common contexts can be prioritized occasionally
    }

    struct Zone: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let context: MusicContext
        let radius: CLLocationDistance
        let score: Double
    }

    // Outside factors that may affect context beyond POI proximity.
    // Weather and speed are live; heart rate / running state are still stubs.
    struct Factors {
        // Simplified weather buckets
        enum Condition {
            case clear
            case rainy
            case snowy
        }

        var weather: Condition? = nil       // from WeatherProviding (WeatherKit)
        var speed: CLLocationSpeed? = nil   // m/s, from CoreLocation
        var heartRate: Int? = nil           // @TODO: Use Apple's healthkit API (NEED PERMISSIONS CHECK) -- HKHeartbeatSeriesQuery
        var isRunning: Bool? = nil          // @TODO: healthkit should be able to track this
    }

    // Above this speed the user is unambiguously in a vehicle — classify as
    // traveling no matter what POIs are nearby. 35 mph, expressed in m/s.
    static let travelingSpeedThreshold: CLLocationSpeed = 35 * 0.44704

    // Hard overrides that trump POI scoring entirely.
    // Rain/snow beats everything (including speed); high speed beats POIs.
    static func contextOverride(for factors: Factors) -> MusicContext? {
        switch factors.weather {
        case .rainy: return .rainy
        case .snowy: return .snowy
        case .clear, nil: break
        }
        if let speed = factors.speed, speed > travelingSpeedThreshold {
            return .traveling
        }
        return nil
    }

    struct Evaluation {
        let context: MusicContext?
        // What would have won on proximity × specificity alone. When this differs
        // from `context`, accumulated debt changed the outcome — ContextDetector
        // uses that signal to arm the anti-flapping switch buffer.
        let contextIgnoringDebt: MusicContext?
        var factors: [Factors]? = nil
        let scores: [MusicContext: Double]
        let zones: [Zone]
    }

    // Debt tuning: a fully indebted context loses up to half of its score —
    // enough for any other nearby context to overtake it at comparable
    // proximity, but never enough to zero a context out entirely. Debt alone
    // can therefore never force a switch; a competing zone must be observed.
    static let maxDebt: Double = 0.5

    static func debtMultiplier(for debt: Double) -> Double {
        1.0 - min(max(debt, 0), maxDebt)
    }


    // Larger, less common places influence a wider area. Common, compact places
    // need the user to be closer before they outweigh their surroundings.
    static let profiles: [MusicContext: Profile] = [
        .beach: Profile(effectiveRadius: 600, specificity: 1.30, debt: 0.0),
        .gym: Profile(effectiveRadius: 120, specificity: 1.05, debt: 0.0),
        .restaurant: Profile(effectiveRadius: 70, specificity: 0.70, debt: 0.0),
        .store: Profile(effectiveRadius: 90, specificity: 0.80, debt: 0.0),
        .park: Profile(effectiveRadius: 600, specificity: 1.20, debt: 0.0),
        .city: Profile(effectiveRadius: 400, specificity: 0.90, debt: 0.0),
    ]

    static var searchRadius: CLLocationDistance {
        (profiles.values.map(\.effectiveRadius).max() ?? 100) * 2
    }

    //@TODO: Bring back the old context categories and allow users to customize their own context pools
    //       This is a good start for testing and current usage though so it's fine until launch
    static let categoryMap: [MKPointOfInterestCategory: MusicContext] = {
        var map: [MKPointOfInterestCategory: MusicContext] = [:]

        for category in [MKPointOfInterestCategory.beach, .marina, .surfing, .swimming, .kayaking, .fishing] {
            map[category] = .beach
        }
        for category in [MKPointOfInterestCategory.fitnessCenter, .baseball, .basketball, .tennis, .soccer, .volleyball, .stadium, .skiing, .golf, .bowling] {
            map[category] = .gym
        }
        for category in [MKPointOfInterestCategory.restaurant, .cafe, .bakery, .brewery, .winery, .distillery] {
            map[category] = .restaurant
        }
        for category in [MKPointOfInterestCategory.store, .foodMarket] {
            map[category] = .store
        }
        for category in [MKPointOfInterestCategory.park, .nationalPark, .campground, .rvPark, .amusementPark, .fairground, .nationalMonument] {
            map[category] = .park
        }
        for category in [MKPointOfInterestCategory.airport, .conventionCenter, .publicTransport, .hotel, .movieTheater, .musicVenue, .nightlife, .theater, .museum, .library, .university, .school, .planetarium, .zoo, .aquarium, .landmark] {
            map[category] = .city
        }

        return map
    }()

    static func context(for category: MKPointOfInterestCategory?) -> MusicContext? {
        guard let category else { return nil }
        return categoryMap[category]
    }

    static func profile(for context: MusicContext) -> Profile? {
        profiles[context]
    }

    static func classify(places: [MKMapItem], userLocation: CLLocation?) -> MusicContext? {
        evaluate(places: places, userLocation: userLocation).context
    }

    // `debts` carries the runtime debt level (0...maxDebt) per context, managed
    // by ContextDetector. Scores are proximity × specificity × debt multiplier.
    // `factors` (weather/speed) can hard-override the POI winner entirely.
    static func evaluate(places: [MKMapItem],
                         userLocation: CLLocation?,
                         debts: [MusicContext: Double] = [:],
                         factors: Factors? = nil) -> Evaluation {
        let override = factors.flatMap { contextOverride(for: $0) }

        guard let userLocation else {
            return Evaluation(context: override, contextIgnoringDebt: override,
                              factors: factors.map { [$0] }, scores: [:], zones: [])
        }

        var contributions: [MusicContext: [Double]] = [:]
        var zones: [Zone] = []

        for item in places {
            guard let context = context(for: item.pointOfInterestCategory),
                  let profile = profile(for: context),
                  let placeLocation = item.placemark.location else {
                continue
            }

            let distance = userLocation.distance(from: placeLocation)
            let proximity = max(0, 1 - (distance / profile.effectiveRadius))
            let score = proximity * profile.specificity
            zones.append(
                Zone(
                    id: zoneID(for: item, context: context),
                    name: item.name ?? context.rawValue,
                    coordinate: item.placemark.coordinate,
                    context: context,
                    radius: profile.effectiveRadius,
                    score: score
                )
            )
            if score > 0 {
                contributions[context, default: []].append(score)
            }
        }

        // The strongest POI defines most of a context's score. Additional nearby
        // POIs add limited evidence so dense restaurant/store clusters do not win
        // solely because those categories are more common in MapKit.
        let rawScores = contributions.mapValues { values in
            let sorted = values.sorted(by: >)
            return sorted.enumerated().reduce(0) { total, entry in
                total + entry.element * pow(0.25, Double(entry.offset))
            }
        }

        // Debt discounts a context that has been active for a while, giving
        // less common neighbors a fair shake — but only contexts that are
        // physically present can win, so debt can never switch on its own.
        let scores = Dictionary(uniqueKeysWithValues: rawScores.map { (context, score) in
            let debt = (debts[context] ?? 0) + (profile(for: context)?.debt ?? 0)
            return (context, score * debtMultiplier(for: debt))
        })

        // Zones and scores are still computed under an override so the map can
        // keep showing nearby context areas — the override only decides the
        // winner.
        return Evaluation(
            context: override ?? winner(of: scores),
            contextIgnoringDebt: override ?? winner(of: rawScores),
            factors: factors.map { [$0] },
            scores: scores,
            zones: zones
        )
    }

    private static func winner(of scores: [MusicContext: Double]) -> MusicContext? {
        scores.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.rawValue > rhs.key.rawValue
            }
            return lhs.value < rhs.value
        }?.key
    }

    // MARK: - Zone identity

    // These IDs are what MapView's ForEach diffs on, so they have to describe
    // the *place* rather than this particular reading of it. Interpolating
    // full-precision coordinates meant a POI whose coordinate moved by a metre
    // between searches came back as a brand new zone, and SwiftUI tore down and
    // rebuilt every circle and annotation instead of leaving them alone.
    //
    // MapKit hands out a stable per-place identifier from iOS 18 onward, and the
    // deployment target is 18.1, so it needs no availability check. It survives
    // coordinate drift, renames and recategorization, which is exactly what we
    // want out of identity.
    private static func zoneID(for item: MKMapItem, context: MusicContext) -> String {
        if let identifier = item.identifier {
            return "poi-\(identifier.rawValue)"
        }
        return coordinateZoneID(for: item, context: context)
    }

    // Not every map item carries an identifier — locally constructed ones never
    // do — so fall back to the coordinate, snapped to a four-decimal grid. That
    // is a cell of ~11m per side, meaning two points sharing a cell are at most
    // ~16m apart, and it absorbs the small drift a repeated search introduces.
    // Name and context stay in the key, so two neighbouring places can only
    // collide if they share a category *and* a name *and* that cell — which is a
    // duplicated POI record, not two distinct places.
    private static func coordinateZoneID(for item: MKMapItem, context: MusicContext) -> String {
        let coordinate = item.placemark.coordinate
        let latitude = String(format: "%.4f", coordinate.latitude)
        let longitude = String(format: "%.4f", coordinate.longitude)
        // prefixed so a coordinate-derived ID can never collide with a MapKit one
        return "geo-\(context.rawValue)-\(latitude)-\(longitude)-\(item.name ?? "")"
    }
}
