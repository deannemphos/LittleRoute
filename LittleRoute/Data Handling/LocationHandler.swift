import Foundation
import CoreLocation
import MapKit
import Observation
import os

@MainActor
@Observable
final class LocationHandler: NSObject, @preconcurrency CLLocationManagerDelegate, POIProviding {
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var search: MKLocalSearch?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var lastAccepted: Date?
    var authorizationStatus: CLAuthorizationStatus?
    var currentLocation: CLLocation?
    var locationMessage: String?
    var hasReducedAccuracy = false
    @ObservationIgnored var onLocationUpdate: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // A distance-only filter would starve dwell after the listener sits down.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    func requestLocationAuthorization() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func requestBackgroundAuthorization() {
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

    func startLocationUpdates() {
        guard manager.authorizationStatus == .authorizedAlways ||
                manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.startUpdatingLocation()
    }

    func stopLocationUpdates() {
        manager.stopUpdatingLocation()
        cancelSearch()
    }

    func getCurrentLocation() -> CLLocation? { currentLocation }

    func cancelSearch() {
        searchGeneration += 1
        search?.cancel()
        search = nil
    }

    func getPointsOfInterest(radius: CLLocationDistance, filter: [MKPointOfInterestCategory]? = nil,
                             completion: @escaping @MainActor (Result<[MKMapItem], Error>) -> Void) {
        guard let location = currentLocation else {
            completion(.failure(CLError(.locationUnknown)))
            return
        }
        cancelSearch()
        let generation = searchGeneration
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: filter ?? Array(ContextClassifier.categoryMap.keys))
        let pending = MKLocalSearch(request: request)
        search = pending
        pending.start { [weak self] response, error in
            Task { @MainActor in
                guard let self, generation == self.searchGeneration else { return }
                self.search = nil
                if let error {
                    completion(.failure(error))
                } else if let response {
                    completion(.success(response.mapItems))
                } else {
                    completion(.failure(CLError(.locationUnknown)))
                }
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        hasReducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationMessage = hasReducedAccuracy ? "Precise location is off. Automatic changes may be unavailable." : nil
            startLocationUpdates()
        case .denied, .restricted:
            currentLocation = nil
            locationMessage = "Location is unavailable. You can still play your music manually."
            stopLocationUpdates()
        case .notDetermined:
            locationMessage = "Enable location to adapt music to your surroundings."
        @unknown default:
            locationMessage = "Location authorization is unavailable."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0, location.horizontalAccuracy.isFinite else { return }
        let age = Date().timeIntervalSince(location.timestamp)
        guard age >= -1, age <= 15 else { return }
        if let previous = currentLocation, location.timestamp <= previous.timestamp { return }
        if let lastAccepted, location.timestamp.timeIntervalSince(lastAccepted) < 5 { return }
        lastAccepted = location.timestamp
        currentLocation = location
        locationMessage = location.horizontalAccuracy > 50
            ? "Location is uncertain. Keeping the current music." : nil
        onLocationUpdate?(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let failure = error as? CLError, failure.code == .locationUnknown {
            locationMessage = "Waiting for a reliable location."
            Log.location.debug("Waiting for a location fix")
        } else {
            locationMessage = "Location is unavailable. Keeping the current music."
            Log.location.error("Location update failed")
        }
    }
}
