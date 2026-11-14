import Foundation
import CoreLocation
import WeatherKit
import os

@MainActor
protocol WeatherProviding {
    func currentCondition(at location: CLLocation,
                          completion: @escaping (ContextClassifier.Factors.Condition?) -> Void)
}

@MainActor
final class WeatherKitProvider: WeatherProviding {
    private let service = WeatherService.shared
    private var cachedCondition: ContextClassifier.Factors.Condition?
    private var cachedAt: Date?
    private var cachedLocation: CLLocation?
    private var inFlight = false
    private var nextAttempt = Date.distantPast
    private var failures = 0

    func currentCondition(at location: CLLocation,
                          completion: @escaping (ContextClassifier.Factors.Condition?) -> Void) {
        Task { @MainActor in
            let fresh = self.cachedAt.map { Date().timeIntervalSince($0) < 600 } == true &&
                self.cachedLocation.map { location.distance(from: $0) < 2_000 } == true
            if fresh {
                completion(self.cachedCondition)
                return
            }
            guard !self.inFlight, Date() >= self.nextAttempt else {
                completion(nil)
                return
            }
            self.inFlight = true
            defer { self.inFlight = false }
            do {
                let current = try await self.service.weather(for: location, including: .current)
                self.cachedCondition = Self.bucket(current.condition)
                self.cachedAt = Date()
                self.cachedLocation = location
                self.failures = 0
                completion(self.cachedCondition)
            } catch {
                self.failures += 1
                self.nextAttempt = Date().addingTimeInterval(min(600, 30 * pow(2, Double(min(self.failures - 1, 5)))))
                Log.weather.error("Weather unavailable; backing off before retry. Check connectivity and WeatherKit provisioning.")
                completion(nil)
            }
        }
    }

    nonisolated static func bucket(_ condition: WeatherCondition) -> ContextClassifier.Factors.Condition {
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
