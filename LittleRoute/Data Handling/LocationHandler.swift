import Foundation
import CoreLocation
import MapKit

// Points of interest reference
// https://developer.apple.com/documentation/mapkit/mkpointofinterestcategory

class LocationHandler: NSObject, ObservableObject, CLLocationManagerDelegate {
    // MARK: - Properties
    private let locationManager = CLLocationManager()
    
    @Published var authorizationStatus: CLAuthorizationStatus?
    @Published var currentLocation: CLLocation?
    @Published var lastKnownLocation: CLLocation? // potentially use to inform next song choice? pass this through an AI model for a monetized "better" music transition?
    @Published var nearbyPlaces: [MKMapItem] = []
    @Published var locationError: Error?
    
    // Init with passthrough of maximum possible accuracy to differentiate between close buildings
    // (hopefully)
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    // MARK: - Public Methods
    
    // Request authorization to use location services  
    //  might move this somewhere else, gotta see how it plays out bc I don't have my mac with me
    // @ TODO: test on simulator and enable the thingy for permissions in the plist
    public func requestLocationAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    /// Start updating location
    public func startLocationUpdates() {
        locationManager.startUpdatingLocation()
    }
    
    // Stop updating location(?) unsure if necessary bc we should always have it enabled while running
    // maybe switch on and off based on user being stationary for saving battery? future consideration to make ig
    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
    }
    
    // Get the current location if available
    public func getCurrentLocation() -> CLLocation? {
        return currentLocation
    }

    public func getPointsOfInterest(radius: CLLocationDistance, filter: [MKPointOfInterestCategory]? = nil, completion: @escaping (Result<[MKMapItem], Error>) -> Void) {
        guard let currentLocation = currentLocation else {
            completion(.success([]))
            return
        }

        // Build a region centered on current coordinate
        let region = MKCoordinateRegion(center: currentLocation.coordinate, latitudinalMeters: radius, longitudinalMeters: radius)

        let request = MKLocalSearch.Request()
        request.region = region
        if let filter = filter {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: filter)
        } else {
            // If no explicit categories provided, restrict to POIs by providing an empty excluding filter
            // so we don't get generic search results that aren't actual POIs
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: MKPointOfInterestCategory.allCases)
        }

        let search = MKLocalSearch(request: request)
        search.start { [weak self] (response: MKLocalSearch.Response?, error: Error?) in
            if let error = error {
                completion(.failure(error))
                return
            }
            let items = response?.mapItems ?? []
            DispatchQueue.main.async {
                self?.nearbyPlaces = items
            }
            completion(.success(items))
        }
    }

    // MARK: - CLLocationManagerDelegate
    // just checks if the user disabled location permissions
    // @TODO: 
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
            print("location auth granted successfully")
        case .denied, .restricted:
            // @TODO: create screen that requests user to grant authorization to continue using the app
            print("**ERROR: location auth failed/not granted!")
        case .notDetermined:
            // Wait for user to make a choice
            print("**ERROR: awaiting user location auth")
        @unknown default:
            break
        }
    }
    
    // create manager with past locations. unsure if necessary yet depending on how geofences/contexts get implemented
    // need to come back to this and share context enums from the music playback branch
    // https://developer.apple.com/documentation/mapkit/mkpointofinterestcategory
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            currentLocation = location
            lastKnownLocation = location
        }
    }
    

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationError = error
    }
}

// @TODO: fix this bs, this is just temporary until i get a build working
//        also inefficient as hell
extension MKPointOfInterestCategory {
    static var allCases: [MKPointOfInterestCategory] {
        // Build in chunks to help the type-checker
        let group1: [MKPointOfInterestCategory] = [
            .airport, .amusementPark, .aquarium, .atm, .bakery, .bank, .beach
        ]
        let group2: [MKPointOfInterestCategory] = [
            .brewery, .cafe, .campground, .carRental, .evCharger, .fireStation
        ]
        let group3: [MKPointOfInterestCategory] = [
            .fitnessCenter, .foodMarket, .gasStation, .hospital, .hotel
        ]
        let group4: [MKPointOfInterestCategory] = [
            .laundry, .library, .marina, .movieTheater, .museum, .nationalPark
        ]
        let group5: [MKPointOfInterestCategory] = [
            .nightlife, .park, .parking, .pharmacy, .police, .postOffice
        ]
        let group6: [MKPointOfInterestCategory] = [
            .publicTransport, .restaurant, .restroom, .school, .stadium
        ]
        let group7: [MKPointOfInterestCategory] = [
            .store, .theater, .university, .winery, .zoo
        ]
        return group1 + group2 + group3 + group4 + group5 + group6 + group7
    }
}

