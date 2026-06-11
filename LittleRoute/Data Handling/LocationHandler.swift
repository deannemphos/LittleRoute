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
    @Published var currentLocationName: String = "Unknown" // User-friendly name for the current location, updated via reverse geocoding in lookUpCurrentLocation
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
    
    // ripped from apple docs -- https://developer.apple.com/documentation/corelocation/converting-between-coordinates-and-user-friendly-place-names
    // reverse geocodes the current location (CLlocation just gives coordinates and shit) to get a user-friendly place name (i.e. Betty's)
    public func lookUpCurrentLocation(completionHandler: @escaping (CLPlacemark?) -> Void ) {
        // Use the last reported location.
        if let lastLocation = self.locationManager.location {
            let geocoder = CLGeocoder()
                
            // Look up the location and pass it to the completion handler
            geocoder.reverseGeocodeLocation(lastLocation,
                        completionHandler: { (placemarks, error) in
                if error == nil {
                    let firstLocation = placemarks?[0]
                    completionHandler(firstLocation)
                }
                else {
                 // An error occurred during geocoding.
                    completionHandler(nil)
                }
            })
        }
        else {
            // No location was available.
            completionHandler(nil)
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

            // set the location name every time we get a new location update for simplicity, can optimize later if this becomes an issue
            lookUpCurrentLocation { [weak self] placemark in
                DispatchQueue.main.async {
                    self?.currentLocationName = placemark?.name ?? "Unknown"
                }
            }    
        
        }
    }
    

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationError = error
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
