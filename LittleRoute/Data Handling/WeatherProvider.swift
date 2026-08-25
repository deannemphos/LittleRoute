import Foundation
import CoreLocation
import WeatherKit

// Abstraction over the weather source so ContextDetector stays testable and
// the app degrades gracefully when WeatherKit is unavailable.
protocol WeatherProviding {
    // Completion is always invoked on the main thread, and always asynchronously —
    // there is no synchronous cache-hit path a caller could be re-entered through.
    // nil means "unknown"; callers should treat that as no weather override.
    //
    // Deliberately not @MainActor, and neither is the parameter @Sendable. Both
    // would be truer descriptions of how this is used, and both would ripple
    // straight into ContextDetector, whose only call site sits in a nonisolated
    // method that a great deal else calls in turn. The requirement stays as loose
    // as the protocol needs to be and WeatherKitProvider keeps the promise on its
    // own side — see currentCondition(at:completion:) there.
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

    // Main actor only, every one of them. currentCondition(at:completion:) is the
    // sole reader and the sole writer of everything from here down, and it does all
    // of it inside a single main-actor closure — see the note there for why the hop
    // moved to the front of the method. Nothing below is safe to touch from a new
    // call site that hasn't got onto main first.
    private var cachedCondition: ContextClassifier.Factors.Condition?
    private var cachedAt: Date?
    private var cachedLocation: CLLocation?
    private var fetchInFlight = false

    // Failure bookkeeping — see noteFailure(_:). Same confinement as the cache
    // above; both helpers are called from inside that closure and nowhere else.
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

    // The hop onto the main actor is now the *first* thing that happens rather than
    // the last, and that reordering is the whole point of this method's shape.
    //
    // The fetch's writes always landed on the main actor. The guards in front of
    // them did not: currentCondition can be called from any thread, so fetchInFlight
    // was read on the caller's thread and written on main, and the three cache
    // fields were read on the caller's thread and written on main right beside it.
    // A guard that reads a value another thread is concurrently writing is a data
    // race however orderly the write is, and what it buys here is precisely the
    // failure the flag exists to prevent — two callers can both see `false`, both
    // set it, and both spend a WeatherKit request against a quota this provider
    // caches for ten minutes specifically to protect.
    //
    // Doing everything inside one main-actor closure collapses that: there is now
    // exactly one thread that ever reads or writes any of this state. It also
    // subsumes the two DispatchQueue.main.async calls the early exits used to make
    // on their own — being on the main actor already is a stronger version of the
    // same promise the protocol makes about `completion`, not a weaker one. The
    // observable difference is only that a cache hit now returns via the concurrency
    // pool rather than the main queue; both were asynchronous before and after, and
    // the sole caller assigns the result to a property.
    //
    // Confinement here is by construction, not by annotation. Marking the stored
    // properties or the type @MainActor would have the compiler enforce what this
    // comment asserts, but WeatherProviding is a nonisolated protocol and
    // ContextDetector calls it from a nonisolated method, so the annotation could
    // not stop at this file: it would have to travel out through evaluate(),
    // start(), refreshNow() and the detector's deinit before it type-checked. That
    // is a much larger change than the race needs, and the race is closed either
    // way. If the cascade is ever paid for, this is the file it starts in.
    func currentCondition(at location: CLLocation,
                          completion: @escaping (ContextClassifier.Factors.Condition?) -> Void) {
        Task { @MainActor in
            if let cachedAt = self.cachedAt, let cachedLocation = self.cachedLocation,
               Date().timeIntervalSince(cachedAt) < self.cacheLifetime,
               location.distance(from: cachedLocation) < self.cacheDistance {
                completion(self.cachedCondition)
                return
            }

            // Don't stack requests while one is pending; report the stale value.
            guard !self.fetchInFlight else {
                completion(self.cachedCondition)
                return
            }
            self.fetchInFlight = true
            // Registered after the flag is raised rather than at the top of the
            // closure, so the two early exits above — which never raised it — can't
            // lower it on somebody else's behalf on their way out.
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
