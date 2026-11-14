#if DEBUG
import CoreLocation
import MapKit

/// Deterministic UI-test data; never substituted in a release build.
@MainActor
final class ContextPreviewProvider: POIProviding {
    var currentLocation: CLLocation?
    var onLocationUpdate: ((CLLocation) -> Void)?
    private var updates: Task<Void, Never>?

    init() {
        currentLocation = CLLocation(coordinate: .init(latitude: 37.3349, longitude: -122.009),
                                     altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                                     course: 0, speed: 0, timestamp: Date())
    }

    deinit { updates?.cancel() }

    func start() {
        guard updates == nil else { return }
        updates = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self, let coordinate = self.currentLocation?.coordinate else { return }
                let fix = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10,
                                     verticalAccuracy: 10, course: 0, speed: 0, timestamp: Date())
                self.currentLocation = fix
                self.onLocationUpdate?(fix)
            }
        }
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
