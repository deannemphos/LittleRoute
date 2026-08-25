import Foundation
import CoreLocation
import MapKit

// Dwell-based area/context detection.
//
// Evaluates nearby POIs every time the location provider hands us a fix, and
// classifies them via ContextClassifier. Detection is driven by location
// delivery, not by a clock — see start() for why that distinction is the whole
// point of this type. A new context only becomes "confirmed" after it has been
// continuously observed for `dwellDuration` — this avoids music flapping when
// walking along the boundary of two areas. When no mappable POI is observed for
// a full dwell window, falls back to the generic .traveling context.
//
// Debt: the confirmed context accrues "debt" over time, but ONLY while the
// user is actively moving — sitting inside the library keeps the library
// context indefinitely. Debt discounts that context's score so common POIs
// (restaurants, stores) can't dominate a whole city walk. Debt by itself can
// never force a switch: a competing zone must actually be observed.
class ContextDetector: ObservableObject {

    // MARK: - Configuration
    // Floor on how often we'll actually run an MKLocalSearch. This is a brake,
    // not a schedule: evaluations are triggered by incoming fixes, and a moving
    // user can clear the provider's distance threshold several times in quick
    // succession. MKLocalSearch is rate-limited, so skip the extras — the next
    // fix brings another chance along with it.
    let minimumSearchInterval: TimeInterval

    // Floor on how far the user has to have moved before we'll spend another
    // one. The interval above only limits how *often* we ask; on its own it
    // still lets someone sitting in a cafe re-ask the same question about the
    // same square, every interval, for as long as they sit there — and get the
    // same answer back every time.
    //
    // 50m is picked against ContextClassifier.profiles: the smallest effective
    // radius there is 70m (restaurants), so even the tightest zone is ~140m
    // across and a walk through one gets sampled two or three times rather
    // than stepped over. It also sits well clear of the drift a genuinely
    // stationary kCLLocationAccuracyBest fix wanders by, so GPS noise alone
    // can't unlock a search. And it's comfortably under the provider's own
    // 400m distance arm, so it never becomes the binding constraint on a
    // moving user — which is the whole point: this is a brake for the
    // stationary case, not a second throttle on the walking one.
    //
    // Gates the *search*, not the evaluation — see evaluate() for why that
    // distinction matters.
    let minimumSearchDisplacement: CLLocationDistance

    // How long a candidate context must persist before switching.
    //
    // Still measured against now(); what changed is that it's *sampled* when
    // location arrives rather than on a fixed cadence. So promotion happens on
    // the first evaluation past the window rather than exactly at it, and
    // switch latency is bounded by the provider's update interval rather than
    // by dwellDuration. The case that would break this — a stationary user
    // generating no events at all, right when dwell should be closing — is
    // handled on the provider side: its throttle has a time arm as well as a
    // distance one, and automatic pausing is disabled, so fixes keep arriving
    // while you sit still.
    let dwellDuration: TimeInterval

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
    // The only signal a context switch travels on. There used to be an
    // onContextChange closure alongside it, and the trouble with a closure is
    // that somebody has to keep it fresh: ContentView's captured `songs`, so
    // every import made the capture stale and the view had to remember to
    // re-assign it. Publishing is enough — an observer reads whatever it needs
    // at the moment the change lands, and there is no second place to update.
    @Published private(set) var confirmedContext: MusicContext
    @Published private(set) var zones: [ContextClassifier.Zone] = []
    @Published private(set) var contextScores: [MusicContext: Double] = [:]
    // Latest known weather bucket, refreshed each evaluation (heavily cached upstream)
    @Published private(set) var latestWeather: ContextClassifier.Factors.Condition?
    // Runtime debt per context, 0...ContextClassifier.maxDebt. Only contexts
    // with a nonzero balance are present.
    @Published private(set) var debts: [MusicContext: Double] = [:]
    private(set) var candidateContext: MusicContext?
    private(set) var candidateSince: Date?
    private(set) var bufferedContext: MusicContext?
    private(set) var bufferExpiry: Date?
    private var lastDebtTick: Date?
    private var lastTickLocation: CLLocation?

    // Weak because the app scope owns the provider and we only borrow it.
    // POIProviding is AnyObject-bound precisely so this can stay weak — a
    // non-class-bound existential has no reference for `weak` to zero out.
    private weak var poiProvider: (any POIProviding)?

    // "Running" means our hook is installed on the provider — there is no timer
    // to hold any more. Kept separate from the hook itself because the provider
    // is weak and may already be gone by the time we're torn down.
    private var isRunning = false
    private var lastSearchStarted: Date?

    // Where the last successful search was centred, and what it handed back.
    // These two move together on purpose: the displacement gate is really
    // asking "am I still standing where the results I'm holding describe?",
    // so a baseline with no results behind it would mean nothing. A search
    // that fails therefore updates neither, and the next fix retries.
    private var lastSearchLocation: CLLocation?
    private var lastSearchPlaces: [MKMapItem]?

    // Injectable clock for testability
    var now: () -> Date = { Date() }

    // weatherProvider has no default on purpose: it used to default to
    // WeatherKitProvider(), which meant every detector — every test detector
    // included — silently built a live WeatherKit client. Pass nil to run
    // without weather overrides; the app passes the real one.
    init(poiProvider: any POIProviding,
         initialContext: MusicContext = .all,
         minimumSearchInterval: TimeInterval = 10,
         minimumSearchDisplacement: CLLocationDistance = 50,
         dwellDuration: TimeInterval = 30,
         searchRadius: CLLocationDistance = ContextClassifier.searchRadius,
         debtAccumulationDuration: TimeInterval? = nil,
         switchBufferDuration: TimeInterval = 180,
         weatherProvider: WeatherProviding?) {
        self.poiProvider = poiProvider
        self.confirmedContext = initialContext
        self.minimumSearchInterval = minimumSearchInterval
        self.minimumSearchDisplacement = minimumSearchDisplacement
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
    // Detection hangs off location delivery. This used to be a repeating Timer,
    // which could never have worked: a scheduled timer does not fire while the
    // app is suspended, so the state machine froze the moment the screen went
    // off — which is most of the time the phone is in a pocket, i.e. exactly
    // when the user is walking somewhere new and the music is supposed to
    // change. LR-11 taught the OS to keep delivering location in the
    // background; this makes the delivery itself the trigger, so the thing that
    // wakes us is the same thing that gives us something new to look at.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Weak self: the app owns both of us, and a strong capture here would
        // pin the detector's lifetime to the provider's.
        poiProvider?.onLocationUpdate = { [weak self] _ in
            self?.evaluate()
        }

        evaluate() // don't sit blind until the next fix arrives
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        // We're the provider's only consumer, so clearing the slot outright is
        // honest rather than rude.
        poiProvider?.onLocationUpdate = nil
    }

    // Force an immediate re-detection, bypassing the dwell window.
    // Used by the "update context" button in the UI.
    public func refreshNow() {
        guard let poiProvider = poiProvider,
              let location = poiProvider.currentLocation else { return }

        // Deliberately jumps both gates: the user asked, out loud, by tapping a
        // button, and "you haven't moved" is not an answer to that. Counts
        // against the rate limit like any other search, so a tap immediately
        // followed by a fix doesn't fire two.
        lastSearchStarted = now()

        poiProvider.getPointsOfInterest(
            radius: searchRadius,
            filter: Array(ContextClassifier.categoryMap.keys)
        ) { [weak self] result in
            guard let self = self, case .success(let places) = result else { return }
            DispatchQueue.main.async {
                // A manual refresh is a real search, so it re-arms the
                // displacement gate and reseeds the cache like any other —
                // otherwise the next fix would immediately buy a second one
                // covering the ground we just paid for.
                self.lastSearchLocation = location
                self.lastSearchPlaces = places

                let evaluation = ContextClassifier.evaluate(
                    places: places,
                    userLocation: poiProvider.currentLocation,
                    debts: self.debts,
                    factors: self.currentFactors()
                )
                let observed = evaluation.context ?? .traveling
                self.zones = evaluation.zones
                self.contextScores = evaluation.scores
                self.candidateContext = nil
                self.candidateSince = nil
                self.clearBuffer() // an explicit user request overrides the anti-flap buffer

                // Same answer as last time, so there is nothing to announce.
                // The early return earns its keep now that the publish is the
                // whole signal: @Published fires on every assignment, equal or
                // not, so writing the same context back would invalidate every
                // observing view to say nothing.
                guard observed != self.confirmedContext else { return }
                self.confirmedContext = observed
                print("ContextDetector: manual refresh switched context to \(observed.rawValue)")
            }
        }
    }

    // MARK: - Detection
    // One evaluation pass: look at what's around us, score it, feed the state
    // machine. Runs on every accepted fix, plus once from start().
    //
    // Two gates sit in front of the MKLocalSearch, and they gate the *search*
    // only — never the pass as a whole. Every fix still walks the state
    // machine, because dwell and debt both advance on evaluations and neither
    // one has anything to do with whether we bought fresh POIs this time.
    //
    // Main thread only: it writes @Published state directly on the gated path.
    // Both callers oblige — start() runs on the app's main actor, and the
    // provider's callback comes off a CLLocationManager delegate created on
    // main.
    private func evaluate() {
        guard let poiProvider = poiProvider,
              let location = poiProvider.currentLocation else { return }

        // Rate limit, not a schedule — see minimumSearchInterval. Dropping a
        // pass is cheap: the next fix brings another one.
        let evaluatedAt = now()
        if let lastSearchStarted,
           evaluatedAt.timeIntervalSince(lastSearchStarted) < minimumSearchInterval { return }

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

        // Displacement gate. Standing still means the next search would centre
        // on the same square and come back with the same places, so don't buy
        // the same answer twice — re-score the ones already in hand.
        //
        // Re-scoring rather than bailing out is the load-bearing half. The
        // dwell window only closes on an evaluation, and the person who has
        // just sat down somewhere is exactly the one whose dwell is about to
        // complete; skipping the pass outright would put back the hole LR-12
        // closed, just reached from the other side. Distances are recomputed
        // against the current fix and the current weather, so drift and a
        // turn in the sky both still move the scores — only the network call
        // is skipped.
        if let lastSearchLocation, let lastSearchPlaces,
           location.distance(from: lastSearchLocation) < minimumSearchDisplacement {
            apply(places: lastSearchPlaces, userLocation: location, speed: speed)
            return
        }

        // A search is only now actually starting, so this is where it starts
        // counting against the rate limit — a gated pass costs MapKit nothing
        // and shouldn't spend the budget.
        lastSearchStarted = evaluatedAt

        poiProvider.getPointsOfInterest(
            radius: searchRadius,
            filter: Array(ContextClassifier.categoryMap.keys)
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let places):
                DispatchQueue.main.async {
                    // The gate's baseline is "where the results we're holding
                    // came from", so it moves here, alongside the results.
                    self.lastSearchLocation = location
                    self.lastSearchPlaces = places
                    self.apply(places: places,
                               userLocation: poiProvider.currentLocation,
                               speed: speed)
                }
            case .failure(let error):
                // Transient search failures shouldn't disturb the state
                // machine — and deliberately leave the gate's baseline where
                // it was, so the next fix gets to retry instead of the user
                // having to walk 50m to earn one.
                print("ContextDetector POI search failed: \(error)")
            }
        }
    }

    // Push one set of places through the classifier and into the state machine.
    // Shared by the fresh-search path and the displacement-gated re-score so
    // the two are identical in everything except where the places came from.
    // Main thread only: writes @Published state.
    private func apply(places: [MKMapItem],
                       userLocation: CLLocation?,
                       speed: CLLocationSpeed?) {
        let factors = ContextClassifier.Factors(weather: latestWeather, speed: speed)
        tickDebt(isMoving: (speed ?? 0) >= movementSpeedThreshold)
        let evaluation = ContextClassifier.evaluate(
            places: places,
            userLocation: userLocation,
            debts: debts,
            factors: factors
        )
        zones = evaluation.zones
        contextScores = evaluation.scores
        process(
            observation: evaluation.context,
            observationIgnoringDebt: evaluation.contextIgnoringDebt
        )
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

    func debt(for context: MusicContext) -> Double {
        debts[context] ?? 0
    }

    // Best-effort current speed in m/s. Prefers the GPS speed reading; when
    // it's unavailable (CLLocation reports -1), falls back to displacement
    // between evaluations. nil when speed can't be determined at all.
    private func currentSpeed() -> CLLocationSpeed? {
        guard let location = poiProvider?.currentLocation else { return nil }
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

    private func isBuffered(_ context: MusicContext) -> Bool {
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
    func process(observation: MusicContext?,
                 observationIgnoringDebt: MusicContext? = nil) {
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
            // Only ever reached on a genuine change — the equality check at the
            // top of this function already returned for anything else — so the
            // publish that follows is always meaningful.
            confirmedContext = observedContext
            candidateContext = nil
            candidateSince = nil
            print("ContextDetector: switched context to \(observedContext.rawValue)")
        }
    }
}
