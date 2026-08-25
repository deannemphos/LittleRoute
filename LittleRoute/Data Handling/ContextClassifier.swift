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
    // traveling no matter what POIs are nearby, and no matter what the sky is
    // doing. 35 mph, expressed in m/s.
    static let travelingSpeedThreshold: CLLocationSpeed = 35 * 0.44704

    // The one remaining hard override, and it is now the top of the pile.
    //
    // Weather used to sit above this and win outright, which meant someone
    // doing 60mph through a shower got rain music — but they are in a car, not
    // in a rainstorm, and the windscreen is the whole point. Speed describes
    // where the user's body is; weather only describes the sky over it. So
    // speed goes first, and weather scores instead (see the Weather section).
    static func contextOverride(for factors: Factors) -> MusicContext? {
        if let speed = factors.speed, speed > travelingSpeedThreshold {
            return .traveling
        }
        return nil
    }

    struct Evaluation {
        let context: MusicContext?
        // What would have won on proximity × specificity × weather alone. When
        // this differs from `context`, accumulated debt changed the outcome —
        // ContextDetector uses that signal to arm the anti-flapping switch
        // buffer. Weather is deliberately on both sides of that comparison: it
        // is a fact about the world, like specificity, whereas debt is a fact
        // about how long we have been sitting in one context. Fold weather into
        // only one side and the two views would disagree every time it rained,
        // which would arm the buffer on switches debt had nothing to do with.
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

    // MARK: - Weather tuning
    //
    // Weather is a second axis, not a winner-take-all. It used to be a hard
    // override — any rain at all returned .rainy, ahead of speed and ahead of
    // every POI — so walking into a gym in a shower got you rain music, and a
    // restaurant in a snowstorm may as well not have existed. It now does two
    // things to the scoreboard instead, both applied before debt.

    // First: what the weather is worth on its own.
    //
    // A flat number, because weather is not a place. .rainy and .snowy have no
    // entry in `profiles`, so there is no effectiveRadius to measure a
    // proximity against and no specificity to weight one by — the sky is simply
    // true everywhere at once, and this constant stands in for the whole
    // proximity × specificity product a POI would have earned.
    //
    // 0.5 is picked against the profile table. The least specific context there
    // is the restaurant at 0.70, so standing in the door of the least
    // distinctive place we recognise still beats the rain, while merely passing
    // within sight of one (proximity below ~0.71, i.e. more than ~20m out on a
    // 70m radius) does not. That is the case this feature actually exists for:
    // an unremarkable street in the rain, where nothing else has a strong
    // claim, so the weather wins by default rather than by fiat.
    static let weatherScore: Double = 0.5

    // Second: what the weather takes away from the places it spoils. An empty
    // beach in a downpour is a rainy day first and a beach second.
    //
    // 0.6 is a slightly gentler cut than a full debt balance (which halves a
    // score), and like debt it can never zero a context out — stand in the
    // middle of a park and the park still wins. At 0.6 the beach's 1.30 tops
    // out at 0.78, so it has to be within ~215m of the pin to clear
    // weatherScore where undamped it would have needed only ~370m.
    static let outdoorWeatherMultiplier: Double = 0.6

    // Only the unambiguously open-air contexts. .city is left alone on purpose:
    // its categories are overwhelmingly indoor venues — museums, theatres,
    // transit halls, hotels — so it is not a context the rain spoils.
    static let outdoorContexts: Set<MusicContext> = [.beach, .park]

    // The context the sky is making a claim for, if any.
    static func weatherContext(for condition: Factors.Condition?) -> MusicContext? {
        switch condition {
        case .rainy: return .rainy
        case .snowy: return .snowy
        case .clear, nil: return nil
        }
    }

    // Mirrors debtMultiplier: what to scale a context's score by given the
    // conditions. 1.0 in fair weather, and 1.0 for anything with a roof.
    static func weatherMultiplier(for context: MusicContext, in condition: Factors.Condition?) -> Double {
        guard weatherContext(for: condition) != nil else { return 1.0 }
        return outdoorContexts.contains(context) ? outdoorWeatherMultiplier : 1.0
    }

    // Folds the weather into a set of POI scores: damp what the weather spoils,
    // then let the weather itself stand on the board as one more candidate.
    // Returns the scores untouched in fair weather, so the common path is free.
    private static func applyWeather(to scores: [MusicContext: Double],
                                     condition: Factors.Condition?) -> [MusicContext: Double] {
        guard let weather = weatherContext(for: condition) else { return scores }

        var adjusted: [MusicContext: Double] = [:]
        for (context, score) in scores {
            adjusted[context] = score * weatherMultiplier(for: context, in: condition)
        }
        // Assigned rather than accumulated: weather is one condition, not a
        // cluster of POIs, so a second reading of it adds no evidence.
        adjusted[weather] = weatherScore
        return adjusted
    }

    // MARK: - Profiles

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

    // How far out the POI search has to reach: far enough that the widest
    // profile above (600m — beach and park) can still be scored from its own
    // edge, and no further. Nothing beyond that can contribute a nonzero
    // proximity, so nothing beyond that is worth asking for.
    //
    // This used to double that figure, and LocationHandler doubled it again
    // turning the query into a 2.4km square. MKLocalSearch caps how many
    // results it hands back, so the surplus reach didn't buy more coverage —
    // it bought an arbitrary sample of a much larger area, and the cafe across
    // the street could simply be absent from it. That made it an accuracy bug
    // before it was ever a cost one.
    //
    // Note this is a *radius*. MKCoordinateRegion wants a span, so the one
    // surviving factor of two lives in LocationHandler.getPointsOfInterest
    // where it's a unit conversion rather than padding.
    static var searchRadius: CLLocationDistance {
        profiles.values.map(\.effectiveRadius).max() ?? 100
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
    // by ContextDetector. Scores are proximity × specificity × weather
    // multiplier × debt multiplier, with the weather itself scoring alongside
    // them. `factors.speed` is the only thing that can still override the
    // winner outright.
    static func evaluate(places: [MKMapItem],
                         userLocation: CLLocation?,
                         debts: [MusicContext: Double] = [:],
                         factors: Factors? = nil) -> Evaluation {
        let override = factors.flatMap { contextOverride(for: $0) }

        // Above the speed threshold the weather doesn't get a vote either: the
        // user is inside a vehicle looking out at it. ContextDetector already
        // stops *fetching* conditions up there, but it keeps the last reading
        // around, so drop it here rather than trusting it to be nil.
        let condition: Factors.Condition? = override == nil ? factors?.weather : nil

        guard let userLocation else {
            // Nothing to score without a fix, so the sky is the only claim left
            // on the table.
            let scores = applyWeather(to: [:], condition: condition)
            let observed = override ?? winner(of: scores)
            return Evaluation(context: observed, contextIgnoringDebt: observed,
                              factors: factors.map { [$0] }, scores: scores, zones: [])
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
        let poiScores = contributions.mapValues { values in
            let sorted = values.sorted(by: >)
            return sorted.enumerated().reduce(0) { total, entry in
                total + entry.element * pow(0.25, Double(entry.offset))
            }
        }

        // Weather joins the scoring here rather than replacing its result:
        // it damps the contexts it spoils and then competes for the win. Sits
        // ahead of debt so that both views below see the same weather — see
        // Evaluation.contextIgnoringDebt for why that matters.
        let rawScores = applyWeather(to: poiScores, condition: condition)

        // Debt discounts a context that has been active for a while, giving
        // less common neighbors a fair shake — but only contexts that are
        // physically present can win, so debt can never switch on its own.
        //
        // .rainy and .snowy fall through this like anything else. They have no
        // profile, so the `?? 0` gives them no baseline debt, but ContextDetector
        // accrues runtime debt against whatever is confirmed while the user
        // moves — so an hour of walking in the rain lets a nearby POI take the
        // context back, exactly as an hour of restaurants would.
        let scores = Dictionary(uniqueKeysWithValues: rawScores.map { (context, score) in
            let debt = (debts[context] ?? 0) + (profile(for: context)?.debt ?? 0)
            return (context, score * debtMultiplier(for: debt))
        })

        // Zones are the POIs themselves, so the weather never appears among
        // them and their scores stay unweathered — a zone describes the place,
        // not today. They're computed under the speed override too, so the map
        // can keep drawing the areas around a moving user.
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
