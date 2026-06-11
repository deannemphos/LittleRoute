import Foundation
import CoreLocation
import MapKit

// Maps MapKit POI categories to the app's predefined music contexts
// (AudioPlayerManager.Context) and classifies the user's current area
// from a set of nearby places.
struct ContextClassifier {

    // POI category -> music context mapping. Categories without an entry
    // are unmapped and don't influence classification.
    static let categoryMap: [MKPointOfInterestCategory: AudioPlayerManager.Context] = {
        var map: [MKPointOfInterestCategory: AudioPlayerManager.Context] = [:]

        // Beaches / water
        for c in [MKPointOfInterestCategory.beach, .marina, .surfing, .swimming, .kayaking, .fishing] {
            map[c] = .beach
        }

        // Gyms
        for c in [MKPointOfInterestCategory.fitnessCenter, .baseball, .basketball, .tennis, .soccer, .volleyball, .stadium, .skiing, .golf, .bowling] {
            map[c] = .gym
        }

        // Restaurants / dining
        for c in [MKPointOfInterestCategory.restaurant, .cafe, .bakery, .brewery, .winery, .distillery, .foodMarket] {
            map[c] = .restaurant
        }

        // Stores / shopping (malls included)
        for c in [MKPointOfInterestCategory.shoppingCenter, .store, .groceryStore, .pharmacy] {
            map[c] = .store
        }

        // Parks / outdoors
        for c in [MKPointOfInterestCategory.park, .nationalPark, .campground, .rvPark, .amusementPark, .fairground, .nationalMonument, .naturalFeature] {
            map[c] = .park
        }

        // City / urban
        for c in [MKPointOfInterestCategory.airport, .conventionCenter, .publicTransport, .hotel, .movieTheater, .musicVenue, .nightlife, .theater, .museum, .library, .university, .school, .planetarium, .zoo, .aquarium, .landmark] {
            map[c] = .city
        }

        return map
    }()

    // Classify a single POI category, nil if unmapped
    static func context(for category: MKPointOfInterestCategory?) -> AudioPlayerManager.Context? {
        guard let category = category else { return nil }
        return categoryMap[category]
    }

    // Classify the user's current area: the nearest place (to userLocation)
    // with a mappable POI category wins. Returns nil when nothing nearby maps.
    static func classify(places: [MKMapItem], userLocation: CLLocation?) -> AudioPlayerManager.Context? {
        let mappable = places.compactMap { item -> (MKMapItem, AudioPlayerManager.Context)? in
            guard let ctx = context(for: item.pointOfInterestCategory) else { return nil }
            return (item, ctx)
        }

        guard !mappable.isEmpty else { return nil }

        guard let userLocation = userLocation else {
            // No reference point; fall back to the first mappable place
            return mappable.first?.1
        }

        let nearest = mappable.min { lhs, rhs in
            distance(from: userLocation, to: lhs.0) < distance(from: userLocation, to: rhs.0)
        }
        return nearest?.1
    }

    private static func distance(from location: CLLocation, to item: MKMapItem) -> CLLocationDistance {
        guard let placeLocation = item.placemark.location else { return .greatestFiniteMagnitude }
        return location.distance(from: placeLocation)
    }
}
