import Foundation
import CoreLocation
import WeatherKit

// Abstraction over the weather source so ContextDetector stays testable and
// the app degrades gracefully when WeatherKit is unavailable.
protocol WeatherProviding {
    // Completion is always invoked on the main thread. nil means "unknown" —
    // callers should treat that as no weather override.
    func currentCondition(at location: CLLocation,
                          completion: @escaping (ContextClassifier.Factors.Condition?) -> Void)
}

// WeatherKit-backed provider.
//
// NOTE: WeatherKit requires the WeatherKit capability/entitlement and an
// active Apple Developer membership. Without them the fetch throws and this
// provider reports nil, so context detection simply proceeds without a
// weather override.
final class WeatherKitProvider: WeatherProviding {
    private let service = WeatherService.shared

    // Weather doesn't change block-to-block; cache aggressively to stay well
    // under WeatherKit's request quota despite the 10s poll cadence.
    private let cacheLifetime: TimeInterval = 10 * 60
    private let cacheDistance: CLLocationDistance = 2_000
    private var cachedCondition: ContextClassifier.Factors.Condition?
    private var cachedAt: Date?
    private var cachedLocation: CLLocation?
    private var fetchInFlight = false

    func currentCondition(at location: CLLocation,
                          completion: @escaping (ContextClassifier.Factors.Condition?) -> Void) {
        if let cachedAt, let cachedLocation,
           Date().timeIntervalSince(cachedAt) < cacheLifetime,
           location.distance(from: cachedLocation) < cacheDistance {
            DispatchQueue.main.async { [cachedCondition] in completion(cachedCondition) }
            return
        }

        // Don't stack requests while one is pending; report the stale value.
        guard !fetchInFlight else {
            DispatchQueue.main.async { [cachedCondition] in completion(cachedCondition) }
            return
        }
        fetchInFlight = true

        Task { @MainActor in
            defer { self.fetchInFlight = false }
            do {
                let current = try await self.service.weather(for: location, including: .current)
                let condition = Self.bucket(current.condition)
                self.cachedCondition = condition
                self.cachedAt = Date()
                self.cachedLocation = location
                completion(condition)
            } catch {
                // Missing entitlement, network failure, quota — all non-fatal
                print("WeatherKitProvider: fetch failed: \(error)")
                completion(nil)
            }
        }
    }

    // Collapse WeatherKit's detailed conditions into the buckets the
    // classifier cares about. Exposed as internal for unit testing.
    static func bucket(_ condition: WeatherCondition) -> ContextClassifier.Factors.Condition {
        switch condition {
        case .drizzle, .rain, .heavyRain, .sunShowers,
             .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms,
             .strongStorms, .hurricane, .tropicalStorm, .hail,
             .freezingDrizzle, .freezingRain:
            return .rainy
        case .flurries, .snow, .heavySnow, .sunFlurries, .blowingSnow,
             .blizzard, .sleet, .wintryMix:
            return .snowy
        default:
            return .clear
        }
    }
}
