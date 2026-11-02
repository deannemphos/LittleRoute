#if DEBUG
import CoreLocation
import MapKit

/// Deterministic UI-test data; never substituted in a release build.
@MainActor
final class ContextPreviewProvider: POIProviding {
    var currentLocation: CLLocation?
    var onLocationUpdate: ((CLLocation) -> Void)?

    init() {
        currentLocation = CLLocation(coordinate: .init(latitude: 37.3349, longitude: -122.009),
                                     altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                                     course: 0, speed: 0, timestamp: Date())
    }

    func getPointsOfInterest(radius: CLLocationDistance, filter: [MKPointOfInterestCategory]?,
                             completion: @escaping @MainActor (Result<[MKMapItem], Error>) -> Void) {
        guard let location = currentLocation else {
            completion(.failure(CLError(.locationUnknown)))
            return
        }
        let projection = ZoneProjection(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        func item(_ name: String, _ category: MKPointOfInterestCategory, x: Double, y: Double) -> MKMapItem {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: projection.coordinate(.init(x: x, y: y))))
            item.name = name
            item.pointOfInterestCategory = category
            return item
        }
        completion(.success([
            item("Example Park", .park, x: 0, y: 0),
            item("Example Gym", .fitnessCenter, x: 180, y: 0),
            item("Example Beach", .beach, x: -350, y: 0),
            item("Example Cafe", .cafe, x: 100, y: 220)
        ]))
    }
}
#endif
