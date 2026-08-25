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
// NOTE: WeatherKit needs two things, and the app bundle only controls one of
// them. The `com.apple.developer.weatherkit` entitlement is in
// LittleRoute.entitlements, but that key is only honoured if the WeatherKit
// capability is also enabled for this App ID on an active Apple Developer
// membership — that half lives in the developer portal, not in the repo.
// With the key present and the capability missing, signing may even fail
// outright; with neither, every fetch throws.
//
// Without them the fetch throws and this provider reports nil, so context
// detection simply proceeds without a weather override — which means .rainy
// and .snowy never fire. See the failure diagnosis below: the point of that
// bookkeeping is that a whole feature going dark should not look like a
// dropped packet.
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

    // Failure bookkeeping — see noteFailure(_:).
    private var consecutiveFailures = 0
    private var everSucceeded = false
    private var diagnosedUnprovisioned = false

    // How many failures in a row, with no success ever, before we stop
    // blaming the network and call it a provisioning problem. Three is
    // ~30s of polling: long enough that a single dropped request or a
    // tunnel doesn't trip it, short enough to see on a first run.
    private static let unprovisionedFailureThreshold = 3

    init() {
        // One line per launch so the feature is at least visible in the
        // console before anything has had a chance to fail. Whether it
        // actually works is answered by the first fetch, either way.
        print("WeatherKitProvider: active — weather overrides require the WeatherKit capability on this App ID.")
    }

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
                self.noteSuccess()
                completion(condition)
            } catch {
                // Missing entitlement, network failure, quota — all non-fatal
                self.noteFailure(error)
                completion(nil)
            }
        }
    }

    // MARK: - Failure diagnosis

    // A missing capability and a flaky network throw the same way here, and
    // the old one-print-per-failure made them read identically: a single
    // buried line that everyone learns to scroll past. The tell isn't the
    // error, it's the pattern — a network blip eventually recovers, an
    // unprovisioned app never succeeds even once. So count failures against
    // "have we ever got an answer this launch" and say the quiet part out
    // loud exactly once when the pattern is conclusive.
    private func noteSuccess() {
        consecutiveFailures = 0
        guard !everSucceeded else { return }
        everSucceeded = true
        print("WeatherKitProvider: first successful fetch — WeatherKit is provisioned; weather overrides are live.")
    }

    private func noteFailure(_ error: Error) {
        consecutiveFailures += 1

        if !everSucceeded,
           !diagnosedUnprovisioned,
           consecutiveFailures >= Self.unprovisionedFailureThreshold {
            diagnosedUnprovisioned = true
            print("""
                WeatherKitProvider: WEATHER DISABLED — \(consecutiveFailures) failed fetches, \
                none successful this launch. That pattern means WeatherKit is not provisioned \
                for \(Bundle.main.bundleIdentifier ?? "this bundle") rather than that the network \
                is flaky. The .rainy and .snowy contexts cannot fire until the WeatherKit \
                capability is enabled for this App ID in the Apple Developer portal and the app \
                is re-signed with a refreshed profile. Last error: \(error)
                """)
            return
        }

        // Ordinary noise, and only while the verdict is still open. Once
        // we've diagnosed, stop reprinting the same error every poll —
        // that spam is what made the original line easy to ignore.
        if !diagnosedUnprovisioned {
            print("WeatherKitProvider: fetch failed (\(consecutiveFailures) in a row): \(error)")
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
