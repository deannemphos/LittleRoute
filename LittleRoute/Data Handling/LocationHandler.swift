import Foundation
import CoreLocation
import MapKit

class LocationHandler: NSObject, ObservableObject, CLLocationManagerDelegate {
    // MARK: - Properties
    private let locationManager = CLLocationManager()
    
    @Published var authorizationStatus: CLAuthorizationStatus?
    @Published var currentLocation: CLLocation?
    @Published var lastKnownLocation: CLLocation? // potentially use to inform next song choice? pass this through an AI model for a monetized "better" music transition?
    @Published var nearbyPlaces: [MKPointOfInterest] = []
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
    
    // MARK: - CLLocationManagerDelegate
    // just checks if the user disabled location permissions
    // @TODO: 
    private func Bool locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        Bool status = false

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
            print("location auth granted successfully")
            status = true
        case .denied, .restricted:
            // @TODO: create screen that requests user to grant authorization to continue using the app
            print("**ERROR: location auth failed/not granted!")
            
        case .notDetermined:
            // Wait for user to make a choice
            print("**ERROR: awaiting user location auth")
            break
        @unknown default:
            break
        }

        return status
    }
    
    // create manager with past locations. unsure if necessary yet depending on how geofences/contexts get implemented
    // need to come back to this and share context enums from the music playback branch
    private func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            currentLocation = location
            lastKnownLocation = location
        }
    }
    

    private func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationError = error
    }
}
