import Foundation
import CoreLocation
import MapKit

@MainActor
protocol POIProviding: AnyObject {
    var currentLocation: CLLocation? { get }
    var onLocationUpdate: ((CLLocation) -> Void)? { get set }
    func getPointsOfInterest(radius: CLLocationDistance,
                             filter: [MKPointOfInterestCategory]?,
                             completion: @escaping @MainActor (Result<[MKMapItem], Error>) -> Void)
    func cancelSearch()
}

extension POIProviding {
    func cancelSearch() {}
}
