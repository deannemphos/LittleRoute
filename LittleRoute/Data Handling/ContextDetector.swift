import Foundation
import CoreLocation
import MapKit

// Dwell-based area/context detection.
//
// Polls nearby POIs on a timer and classifies them via ContextClassifier.
// A new context only becomes "confirmed" after it has been continuously
// observed for `dwellDuration` — this avoids music flapping when walking
// along the boundary of two areas. When no mappable POI is observed for a
// full dwell window, falls back to the generic .traveling context.
//
// Debt: the confirmed context accrues "debt" over time, but ONLY while the
// user is actively moving — sitting inside the library keeps the library
// context indefinitely. Debt discounts that context's score so common POIs
// (restaurants, stores) can't dominate a whole city walk. Debt by itself can
// never force a switch: a competing zone must actually be observed.
class ContextDetector: ObservableObject {

    // MARK: - Configuration
    let pollInterval: TimeInterval   // how often to query POIs (MKLocalSearch is rate-limited, keep this modest)
    let dwellDuration: TimeInterval  // how long a candidate context must persist before switching
    let searchRadius: CLLocationDistance

    // Time of continuous movement for the confirmed context to reach full debt.
    // User-tunable via UserDefaults (see debtAccumulationDefaultsKey);
    // defaults to 8 minutes. Drop to 120 for field testing.
    let debtAccumulationDuration: TimeInterval
    static let defaultDebtAccumulationDuration: TimeInterval = 8 * 60
    static let debtAccumulationDefaultsKey = "contextDebtAccumulationDuration"

    // Buffer window after a debt-driven switch: the context we just left can't
    // win again until this elapses or its debt drains, whichever comes first.
    // Prevents jittery back-and-forth flapping in POI-cluttered areas.
    let switchBufferDuration: TimeInterval

    // Speeds above this (m/s) count as "actively traveling" — roughly a slow walk.
    private let movementSpeedThreshold: CLLocationSpeed = 0.5

    // Source of current weather conditions; nil disables weather overrides.
    private let weatherProvider: WeatherProviding?

    // MARK: - State
    @Published private(set) var confirmedContext: AudioPlayerManager.Context
    @Published private(set) var zones: [ContextClassifier.Zone] = []
    @Published private(set) var contextScores: [AudioPlayerManager.Context: Double] = [:]
    // Latest known weather bucket, refreshed each poll (heavily cached upstream)
    @Published private(set) var latestWeather: ContextClassifier.Factors.Condition?
    // Runtime debt per context, 0...ContextClassifier.maxDebt. Only contexts
    // with a nonzero balance are present.
    @Published private(set) var debts: [AudioPlayerManager.Context: Double] = [:]
    private(set) var candidateContext: AudioPlayerManager.Context?
    private(set) var candidateSince: Date?
    private(set) var bufferedContext: AudioPlayerManager.Context?
    private(set) var bufferExpiry: Date?
    private var lastDebtTick: Date?
    private var lastTickLocation: CLLocation?

    // Fired on the main thread whenever a new context is confirmed
    var onContextChange: ((AudioPlayerManager.Context) -> Void)?

    private weak var locationHandler: LocationHandler?
    private var pollTimer: Timer?

    // Injectable clock for testability
    var now: () -> Date = { Date() }

    init(locationHandler: LocationHandler,
         initialContext: AudioPlayerManager.Context = .all,
         pollInterval: TimeInterval = 10,
         dwellDuration: TimeInterval = 30,
         searchRadius: CLLocationDistance = ContextClassifier.searchRadius,
         debtAccumulationDuration: TimeInterval? = nil,
         switchBufferDuration: TimeInterval = 180,
         weatherProvider: WeatherProviding? = WeatherKitProvider()) {
        self.locationHandler = locationHandler
        self.confirmedContext = initialContext
        self.pollInterval = pollInterval
        self.dwellDuration = dwellDuration
        self.searchRadius = searchRadius

        let stored = UserDefaults.standard.double(forKey: Self.debtAccumulationDefaultsKey)
        let resolved = debtAccumulationDuration ?? (stored > 0 ? stored : Self.defaultDebtAccumulationDuration)
        self.debtAccumulationDuration = resolved > 0 ? resolved : Self.defaultDebtAccumulationDuration
        self.switchBufferDuration = switchBufferDuration
        self.weatherProvider = weatherProvider
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle
    public func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll() // kick off an immediate first check
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // Force an immediate re-detection, bypassing the dwell window.
    // Used by the "update context" button in the UI.
    public func refreshNow() {
        guard let locationHandler = locationHandler,
              locationHandler.currentLocation != nil else { return }

        locationHandler.getPointsOfInterest(
            radius: searchRadius,
            filter: Array(ContextClassifier.categoryMap.keys)
        ) { [weak self] result in
            guard let self = self, case .success(let places) = result else { return }
            DispatchQueue.main.async {
                let evaluation = ContextClassifier.evaluate(
                    places: places,
                    userLocation: locationHandler.currentLocation,
                    debts: self.debts,
                    factors: self.currentFactors()
                )
                let observed = evaluation.context ?? .traveling
                self.zones = evaluation.zones
                self.contextScores = evaluation.scores
                self.candidateContext = nil
                self.candidateSince = nil
                self.clearBuffer() // an explicit user request overrides the anti-flap buffer
                guard observed != self.confirmedContext else { return }
                self.confirmedContext = observed
                print("ContextDetector: manual refresh switched context to \(observed.rawValue)")
                self.onContextChange?(observed)
            }
        }
    }

    // MARK: - Detection
    private func poll() {
        guard let locationHandler = locationHandler,
              let location = locationHandler.currentLocation else { return }

        let speed = currentSpeed()

        // Refresh weather out-of-band; the next evaluation picks up the stored
        // value. Skipped entirely at highway speeds (>35mph) — the speed
        // override decides the context anyway, so don't burn WeatherKit quota
        // from a moving car. The last known condition is kept until the user
        // slows back down and the fetch resumes.
        if (speed ?? 0) <= ContextClassifier.travelingSpeedThreshold {
            weatherProvider?.currentCondition(at: location) { [weak self] condition in
                self?.latestWeather = condition
            }
        }

        locationHandler.getPointsOfInterest(
            radius: searchRadius,
            filter: Array(ContextClassifier.categoryMap.keys)
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let places):
                DispatchQueue.main.async {
                    let factors = ContextClassifier.Factors(weather: self.latestWeather, speed: speed)
                    self.tickDebt(isMoving: (speed ?? 0) >= self.movementSpeedThreshold)
                    let evaluation = ContextClassifier.evaluate(
                        places: places,
                        userLocation: locationHandler.currentLocation,
                        debts: self.debts,
                        factors: factors
                    )
                    self.zones = evaluation.zones
                    self.contextScores = evaluation.scores
                    self.process(
                        observation: evaluation.context,
                        observationIgnoringDebt: evaluation.contextIgnoringDebt
                    )
                }
            case .failure(let error):
                // Transient search failures shouldn't disturb the state machine
                print("ContextDetector POI search failed: \(error)")
            }
        }
    }

    // Snapshot of the live external factors feeding the classifier.
    private func currentFactors() -> ContextClassifier.Factors {
        ContextClassifier.Factors(weather: latestWeather, speed: currentSpeed())
    }

    // MARK: - Debt
    // Advances every context's debt by the time elapsed since the last tick.
    // Only the confirmed context accrues, and ONLY while the user is moving —
    // sitting still (e.g. at the library) never builds debt. Everything else
    // (including the confirmed context while stationary) drains at the same
    // rate. Exposed as internal (not private) for unit testing.
    func tickDebt(isMoving: Bool) {
        let currentTime = now()
        defer { lastDebtTick = currentTime }
        guard let lastTick = lastDebtTick else { return }

        let elapsed = currentTime.timeIntervalSince(lastTick)
        guard elapsed > 0 else { return }
        let delta = ContextClassifier.maxDebt * (elapsed / debtAccumulationDuration)

        var updated = debts
        for context in Set(updated.keys).union([confirmedContext]) {
            let accruing = isMoving && context == confirmedContext
            let balance = (updated[context] ?? 0) + (accruing ? delta : -delta)
            updated[context] = min(max(balance, 0), ContextClassifier.maxDebt)
        }
        debts = updated.filter { $0.value > 0 }

        // Release the switch buffer early once the departed context's debt
        // has fully ticked back down.
        if let buffered = bufferedContext, debts[buffered] == nil {
            clearBuffer()
        }
    }

    func debt(for context: AudioPlayerManager.Context) -> Double {
        debts[context] ?? 0
    }

    // Best-effort current speed in m/s. Prefers the GPS speed reading; when
    // it's unavailable (CLLocation reports -1), falls back to displacement
    // between polls. nil when speed can't be determined at all.
    private func currentSpeed() -> CLLocationSpeed? {
        guard let location = locationHandler?.currentLocation else { return nil }
        defer { lastTickLocation = location }

        if location.speed >= 0 {
            return location.speed
        }
        guard let previous = lastTickLocation else { return nil }
        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return nil }
        return location.distance(from: previous) / elapsed
    }

    private func clearBuffer() {
        bufferedContext = nil
        bufferExpiry = nil
    }

    private func isBuffered(_ context: AudioPlayerManager.Context) -> Bool {
        guard let bufferedContext, let bufferExpiry else { return false }
        guard now() < bufferExpiry else {
            clearBuffer()
            return false
        }
        return context == bufferedContext
    }

    // State machine: promote an observed context to confirmed only after it
    // has been observed continuously for dwellDuration. A nil observation
    // (no mappable POI nearby) is treated as a .traveling candidate.
    //
    // `observationIgnoringDebt` is what would have won without debt applied.
    // When the two disagree at promotion time, the switch was debt-driven and
    // the departed context enters the buffer: it can't win again until the
    // buffer window elapses or its debt drains, whichever comes first.
    // Exposed as internal (not private) for unit testing.
    func process(observation: AudioPlayerManager.Context?,
                 observationIgnoringDebt: AudioPlayerManager.Context? = nil) {
        let observedContext = observation ?? .traveling
        let debtFreeWinner = observationIgnoringDebt ?? observation

        if observedContext == confirmedContext || isBuffered(observedContext) {
            // Still in the same area — or seeing a context that's serving its
            // buffer sentence — drop any pending candidate
            candidateContext = nil
            candidateSince = nil
            return
        }

        if observedContext != candidateContext {
            // New candidate — restart the dwell clock
            candidateContext = observedContext
            candidateSince = now()
            return
        }

        // Same candidate as before — promote once the dwell window has elapsed
        if let since = candidateSince, now().timeIntervalSince(since) >= dwellDuration {
            // Debt-driven switch: without debt the confirmed context would
            // still be winning. Buffer it so we can't flap right back.
            if debtFreeWinner == confirmedContext {
                bufferedContext = confirmedContext
                bufferExpiry = now().addingTimeInterval(switchBufferDuration)
            }
            confirmedContext = observedContext
            candidateContext = nil
            candidateSince = nil
            print("ContextDetector: switched context to \(observedContext.rawValue)")
            onContextChange?(observedContext)
        }
    }
}
