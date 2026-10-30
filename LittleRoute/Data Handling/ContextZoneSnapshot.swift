import Foundation
import MapKit

struct ZoneProjection: Sendable {
    let latitude: Double
    let longitude: Double
    private static let metersPerDegree = 6_371_000.0 * Double.pi / 180

    func point(latitude: Double, longitude: Double) -> ContextZoneGeometry.Point {
        var delta = (longitude - self.longitude).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return .init(x: delta * Self.metersPerDegree * cos(self.latitude * .pi / 180),
                     y: (latitude - self.latitude) * Self.metersPerDegree)
    }

    func coordinate(_ point: ContextZoneGeometry.Point) -> CLLocationCoordinate2D {
        var lon = longitude + point.x / (Self.metersPerDegree * cos(latitude * .pi / 180))
        lon = (lon + 180).truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        return CLLocationCoordinate2D(latitude: latitude + point.y / Self.metersPerDegree,
                                     longitude: lon - 180)
    }
}

@MainActor
struct ContextZoneSnapshot {
    struct MapRegion: Identifiable {
        let id: String
        let context: MusicContext
        let polygon: MKPolygon
    }

    let geometry: ContextZoneGeometry
    let projection: ZoneProjection
    let generatedAt: Date
    let regions: [MapRegion]

    init(geometry: ContextZoneGeometry, projection: ZoneProjection, generatedAt: Date) {
        self.geometry = geometry
        self.projection = projection
        self.generatedAt = generatedAt
        self.regions = geometry.regions.compactMap { region in
            guard let context = MusicContext(storageKey: region.context) else { return nil }
            let holes = region.holes.map { ring in
                let coordinates = ring.map(projection.coordinate)
                return MKPolygon(coordinates: coordinates, count: coordinates.count)
            }
            let coordinates = region.outline.map(projection.coordinate)
            return MapRegion(id: region.id, context: context,
                             polygon: MKPolygon(coordinates: coordinates, count: coordinates.count,
                                                interiorPolygons: holes))
        }
    }

    func point(for location: CLLocation) -> ContextZoneGeometry.Point {
        projection.point(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }
}
