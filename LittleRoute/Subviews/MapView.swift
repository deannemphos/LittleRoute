//
//  MapView.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 5/14/26.
//

import SwiftUI
import MapKit

struct MapView: View {
    @ObservedObject var contextDetector: ContextDetector
    var context: MusicContext

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    
    /*
    @State private var visiblePOIs: [MKMapItem] = []
    // @TODO: remove this manual filtering, make it work with custom categories that can be set by the user in the future
    // Maps the active audio context to relevant MapKit POI categories
    private var contextCategories: [MKPointOfInterestCategory] {
        switch context {
        case .all:        return MKPointOfInterestCategory.allCases
        case .gym:        return [.fitnessCenter, .stadium]
        case .restaurant: return [.restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket]
        case .store:      return [.store, .foodMarket]
        case .park:       return [.park, .nationalPark, .campground]
        case .beach:      return [.beach, .marina]
        case .mountain:   return [.nationalPark, .campground]
        case .city:       return [.museum, .movieTheater, .nightlife, .theater, .amusementPark, .aquarium, .zoo]
        case .town:       return [.library, .postOffice, .school, .publicTransport]
        case .water:      return [.marina, .beach]
        case .driving:    return [.gasStation, .carRental, .evCharger, .parking]
        case .street:     return [.publicTransport, .parking]
        case .home, .work: return []
        case .traveling: return []
        }
    }
    */
    
    var body: some View {
        Map(position: $position) {
            // Diffs on Zone.id, so every poll that rediscovers the same places
            // should reuse these circles and annotations rather than replace
            // them — see ContextClassifier.zoneID for how that ID stays put.
            ForEach(contextDetector.zones) { zone in
                let color = zone.context.tintColor
                let isActive = zone.context == context

                MapCircle(center: zone.coordinate, radius: zone.radius)
                    .foregroundStyle(color.opacity(isActive ? 0.28 : 0.12))
                    .stroke(color.opacity(isActive ? 0.95 : 0.55), lineWidth: isActive ? 3 : 1)

                Annotation(zone.name, coordinate: zone.coordinate) {
                    Image(systemName: zone.context.iconName)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(color, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: isActive ? 2 : 1))
                        // a bare SF Symbol announces its own name ("figure.run"), which
                        // tells you nothing about which place you're standing in
                        .accessibilityLabel("\(zone.name), \(zone.context.displayName)")
                }
            }

            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .accessibilityLabel("Nearby music context zones")
    }
}
