//
//  MapView.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 5/14/26.
//


import SwiftUI
import MapKit

struct MapView: View {
    @ObservedObject var locationHandler: LocationHandler
    var context: AudioPlayerManager.Context

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
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
        }
    }

    var body: some View {
        Map(position: $position) {
            UserAnnotation()

            ForEach(visiblePOIs, id: \.self) { item in
                Annotation(item.name ?? "", coordinate: item.placemark.coordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onAppear { refreshPOIs() }
        .onChange(of: locationHandler.currentLocation) { _, _ in refreshPOIs() }
        .onChange(of: context) { _, _ in refreshPOIs() }
    }

    private func refreshPOIs() {
        let categories = contextCategories
        guard !categories.isEmpty else {
            visiblePOIs = []
            return
        }
        locationHandler.getPointsOfInterest(radius: 500, filter: categories) { result in
            if case .success(let items) = result {
                visiblePOIs = items
            }
        }
    }
}
