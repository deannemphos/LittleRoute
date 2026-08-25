import Foundation
import CoreLocation
import MapKit

// Points of interest reference
// https://developer.apple.com/documentation/mapkit/mkpointofinterestcategory

// POIProviding is the two-member slice ContextDetector talks to; the members
// below already satisfy it, so conforming here costs nothing and lets the
// detector be built against a stub instead of a real CLLocationManager.
class LocationHandler: NSObject, ObservableObject, CLLocationManagerDelegate, POIProviding {
    // MARK: - Properties
    private let locationManager = CLLocationManager()
    
    // keep this list short: ContentView observes the whole object just to read
    // authorizationStatus, so anything published here re-invalidates its body.
    @Published var authorizationStatus: CLAuthorizationStatus?
    @Published var currentLocation: CLLocation?

    // Throttling: accept a new location only after this much time has passed
    // since the last accepted update, or when the user has moved farther than
    // the distance threshold. Saves battery and avoids redundant POI churn.
    private let updateInterval: TimeInterval = 60
    private let significantDistance: CLLocationDistance = 400
    private var lastAcceptedLocation: CLLocation?
    private var lastAcceptedTime: Date?
    
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
        let region = MKCoordinateRegion(
            center: currentLocation.coordinate,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )

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
        search.start { (response: MKLocalSearch.Response?, error: Error?) in
            if let error = error {
                completion(.failure(error))
                return
            }
            // results go to the caller only -- we deliberately don't stash them on
            // the handler, that used to republish on every poll for nobody's benefit
            completion(.success(response?.mapItems ?? []))
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
        guard let location = locations.last else { return }

        // Throttle: only accept the update if 60s have passed since the last
        // accepted one, or the user moved more than 400m. The first update is
        // always accepted.
        if let lastLocation = lastAcceptedLocation, let lastTime = lastAcceptedTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            let distance = location.distance(from: lastLocation)
            guard elapsed >= updateInterval || distance > significantDistance else { return }
        }

        lastAcceptedLocation = location
        lastAcceptedTime = Date()

        currentLocation = location
    }


    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // this used to land in a published var nobody read, which is a fancy way of
        // saying it vanished. print keeps it visible until LR-26 swaps in a Logger.
        // @TODO: replace with Logger(subsystem:category:) and decide whether the user
        //        ever needs to see this (kCLErrorLocationUnknown is transient noise)
        print("**ERROR: location manager failed -- \(error.localizedDescription)")
    }
}

// @TODO: fix this bs, this is just temporary until i get a build working
//        also inefficient as hell
//        grouping these together for future reference  
extension MKPointOfInterestCategory {
    static var allCases: [MKPointOfInterestCategory] {
        // Build in chunks to help the type-checker
        let aquatic: [MKPointOfInterestCategory] = [
            .aquarium, .beach, .marina, .fishing, .kayaking, .surfing, .swimming
        ]
        let sports: [MKPointOfInterestCategory] = [
            .baseball, .basketball, .bowling, .golf, .fitnessCenter, .stadium, .tennis, .skiing, .soccer, .stadium, .tennis, .volleyball
        ]
        let dining: [MKPointOfInterestCategory] = [
            .bakery, .brewery, .cafe, .distillery, .foodMarket, .restaurant, .winery
        ]
        let parks: [MKPointOfInterestCategory] = [
            .amusementPark, .campground, .fairground, .landmark, .nationalPark, .park, .rvPark
        ]
        let nightlife: [MKPointOfInterestCategory] = [
            .miniGolf, .movieTheater, .musicVenue, .nightlife, .park, .parking, .pharmacy, .police, .postOffice
        ]
        let city: [MKPointOfInterestCategory] = [
            .airport, .conventionCenter, .publicTransport, .hotel
        ]
        let education: [MKPointOfInterestCategory] = [
            .library, .museum, .nationalMonument,.planetarium, .school, .theater, .university, .zoo
        ]
        /*
        let markets: [MKPointOfInterestCategory] = [
            .groceryStore, .shoppingCenter, .store
        ]
        let rural: [MKPointOfInterestCategory] = [
            .landmark, .naturalFeature
        ]
        let other: [MKPointOfInterestCategory] = [
            .other
        ]
         */
        return aquatic + sports + dining + parks + nightlife + city + education // + markets + rural + other
    }
}

/*
// UNUSED:
.goKart
*/
