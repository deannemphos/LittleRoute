import Foundation
import CoreLocation
import MapKit

struct ContextClassifier {
    struct Profile {
        let effectiveRadius: CLLocationDistance
        // let weight: Double
        
        let specificity: Double // How specific this context is, a higher specificity means it's less common and should be weighted more heavily in the scoring algorithm
        let debt: Double // how much "debt" this one is compared to other contexts. Accumulate debt the longer a context has been active for so less common contexts can be prioritized occasionally
    }

    struct Zone: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let context: AudioPlayerManager.Context
        let radius: CLLocationDistance
        let score: Double
    }

    struct Evaluation {
        let context: AudioPlayerManager.Context?
        let scores: [AudioPlayerManager.Context: Double]
        let zones: [Zone]
    }

    // Larger, less common places influence a wider area. Common, compact places
    // need the user to be closer before they outweigh their surroundings.
    static let profiles: [AudioPlayerManager.Context: Profile] = [
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
    static let categoryMap: [MKPointOfInterestCategory: AudioPlayerManager.Context] = {
        var map: [MKPointOfInterestCategory: AudioPlayerManager.Context] = [:]

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

    static func context(for category: MKPointOfInterestCategory?) -> AudioPlayerManager.Context? {
        guard let category else { return nil }
        return categoryMap[category]
    }

    static func profile(for context: AudioPlayerManager.Context) -> Profile? {
        profiles[context]
    }

    static func classify(places: [MKMapItem], userLocation: CLLocation?) -> AudioPlayerManager.Context? {
        evaluate(places: places, userLocation: userLocation).context
    }

    static func evaluate(places: [MKMapItem], userLocation: CLLocation?) -> Evaluation {
        guard let userLocation else {
            return Evaluation(context: nil, scores: [:], zones: [])
        }

        var contributions: [AudioPlayerManager.Context: [Double]] = [:]
        var zones: [Zone] = []

        for item in places {
            guard let context = context(for: item.pointOfInterestCategory),
                  let profile = profile(for: context),
                  let placeLocation = item.placemark.location else {
                continue
            }

            let distance = userLocation.distance(from: placeLocation)
            let proximity = max(0, 1 - (distance / profile.effectiveRadius))
            let score = proximity * profile.weight
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
        let scores = contributions.mapValues { values in
            let sorted = values.sorted(by: >)
            return sorted.enumerated().reduce(0) { total, entry in
                total + entry.element * pow(0.25, Double(entry.offset))
            }
        }
        let winner = scores.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.rawValue > rhs.key.rawValue
            }
            return lhs.value < rhs.value
        }?.key

        return Evaluation(context: winner, scores: scores, zones: zones)
    }

    private static func zoneID(for item: MKMapItem, context: AudioPlayerManager.Context) -> String {
        let coordinate = item.placemark.coordinate
        return "\(context.rawValue)-\(coordinate.latitude)-\(coordinate.longitude)-\(item.name ?? "")"
    }
}
