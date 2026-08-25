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
    
    // iOS shows the "keep using in the background?" upgrade prompt exactly once per
    // install, so this stops us re-asking every time the delegate fires. it does not
    // need to persist across launches -- a repeat call is a no-op at the OS level,
    // this just keeps us from spamming it within a session.
    private var hasRequestedAlwaysUpgrade = false

    // Init with passthrough of maximum possible accuracy to differentiate between close buildings
    // (hopefully)
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest

        // the entire premise of this app is music that changes as you move, which
        // does not survive the screen going off: CoreLocation stops delivering the
        // moment we background, while the audio session happily keeps playing. this
        // is what keeps updates coming.
        // NB: this line *traps* if UIBackgroundModes in Info.plist is missing the
        //     `location` value -- it's a hard crash, not a polite failure, so the
        //     plist entry and this line have to move together.
        locationManager.allowsBackgroundLocationUpdates = true

        // and put the blue indicator in the status bar while we do it. we are
        // following you down the street; the least we can do is admit it.
        locationManager.showsBackgroundLocationIndicator = true
    }
    
    // MARK: - Public Methods
    
    // Request authorization to use location services  
    //  might move this somewhere else, gotta see how it plays out bc I don't have my mac with me
    // this is deliberately still the *when in use* ask and nothing more. asking for
    // always straight out of a cold start does not work -- iOS quietly drops an
    // always-request made from .notDetermined, and we'd burn our one prompt for
    // nothing. the upgrade happens in locationManagerDidChangeAuthorization once
    // when-in-use is actually on the books.
    // @TODO: test the two-step prompt on a real device, the simulator fakes it
    public func requestLocationAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    // Step two: upgrade when-in-use to always, so location keeps arriving once the
    // screen locks. only ever called from the delegate after when-in-use is granted.
    // we get one shot at this prompt for the lifetime of the install, hence the flag
    // -- and if the user says no we just carry on with when-in-use, which still gets
    // us background updates while audio is playing, just more fragile ones.
    private func requestAlwaysUpgradeIfNeeded() {
        guard !hasRequestedAlwaysUpgrade else { return }
        hasRequestedAlwaysUpgrade = true
        locationManager.requestAlwaysAuthorization()
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
    // checks if the user disabled location permissions, and drives the second half
    // of the two-step authorization dance (when-in-use -> always). this fires once
    // on delegate assignment with whatever we already had, so an existing install
    // that only granted when-in-use gets offered the upgrade on next launch.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            print("location auth granted successfully (when in use)")
            // now, and only now, is the always-prompt worth spending -- iOS will
            // actually show it once when-in-use is already granted.
            requestAlwaysUpgradeIfNeeded()
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
            print("location auth granted successfully (always)")
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
