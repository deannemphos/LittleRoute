import Foundation
import CoreLocation
import MapKit

// The slice of LocationHandler that ContextDetector actually consumes.
//
// The detector only ever asks two things: where are we, and what's around us.
// Naming the concrete class dragged the whole CLLocationManager along with it —
// an authorization prompt and a live MKLocalSearch got built by anything that
// so much as constructed a detector, tests included. This is that slice and
// nothing else, so a stub can stand in for the real thing.
//
// Class-bound on purpose: ContextDetector holds its provider weakly (the app
// owns it, the detector borrows it), and `weak` needs a class-bound existential
// to have a reference it's allowed to zero out. Nothing is lost — the handler
// is a class already, and so is any stub worth writing.
protocol POIProviding: AnyObject {
    // Latest accepted fix, or nil until the first one lands.
    var currentLocation: CLLocation? { get }

    // Fired whenever the provider accepts a new fix. This is the detector's
    // clock: one evaluation pass per delivered location, instead of a Timer
    // that stops firing the moment the app is suspended. A single slot rather
    // than a broadcast because there is exactly one consumer — the detector
    // installs it in start() and clears it in stop().
    var onLocationUpdate: ((CLLocation) -> Void)? { get set }

    // Results arrive through the completion handler only -- nothing gets stashed
    // on the provider. Completion lands on whatever queue the search finished
    // on, so callers hop to main themselves.
    //
    // @NOTE: no default for `filter` here — protocol requirements can't carry
    //        default arguments, so calls made through the protocol always pass
    //        one. LocationHandler keeps its own default for direct callers.
    func getPointsOfInterest(radius: CLLocationDistance,
                             filter: [MKPointOfInterestCategory]?,
                             completion: @escaping (Result<[MKMapItem], Error>) -> Void)
}
