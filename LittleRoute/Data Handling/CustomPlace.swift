import Foundation

/// A user-defined point of interest. ContextDetector keeps these as JSON in its
/// key-value store: there are only ever a handful, so they stay out of the
/// SwiftData schema and its migration plan.
struct CustomPlace: Codable, Identifiable, Equatable, Sendable {
    /// GPS indoors is often 30-65 m off and a switch needs the listener well
    /// inside the zone, so small radii rarely confirm. Tune on a device.
    static let radiusRange = 50.0...500.0
    static let defaultRadius = 150.0
    static let maximumNameLength = 60

    var id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
    /// A MusicContext storage key.
    let contextKey: String
    let radius: Double

    /// nil when the input cannot describe a place on the map.
    init?(name: String, latitude: Double, longitude: Double, contextKey: String,
          radius: Double = CustomPlace.defaultRadius) {
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNameLength))
        self.latitude = latitude
        self.longitude = longitude
        self.contextKey = contextKey
        self.radius = radius.isFinite
            ? min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound) : Self.defaultRadius
        guard isValid else { return nil }
    }

    /// Decoded places skip the initializer, so the detector rechecks this
    /// before handing one to the zone geometry.
    var isValid: Bool {
        !name.isEmpty && !contextKey.isEmpty && latitude.isFinite && longitude.isFinite &&
            abs(latitude) < 85 && abs(longitude) <= 180 && Self.radiusRange.contains(radius)
    }
}
