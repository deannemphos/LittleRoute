import Foundation
import CoreLocation
import MapKit
import Observation
import os

// The narrow slice of UserDefaults this file touches, behind a protocol for
// exactly the reason POIProviding and WeatherProviding are: constructing a
// detector should not reach into the app's real defaults domain, least of all
// from a test that then leaves its state lying there for the next one.
// UserDefaults satisfies this as written — these are its own signatures, so the
// conformance is empty rather than an adapter.
protocol KeyValueStoring {
    func data(forKey defaultName: String) -> Data?
    func double(forKey defaultName: String) -> Double
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: KeyValueStoring {}

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
//
// Some of that state outlives the process — see the Persistence section for
// which parts and why. It has to: LR-11 put the app on background location, so
// being jetsammed and relaunched is now routine rather than exotic, and a
// detector that woke up remembering nothing would hand the user a fresh
// context reshuffle every time the OS reclaimed some memory.
@Observable
class ContextDetector {

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

    // How old persisted state may be and still count as evidence about where
    // the user is *now*.
    //
    // Six hours, picked against what each mistake costs. The case this exists
    // for is a background jetsam or a force-quit — seconds to minutes — and a
    // lunch break, a meeting, an afternoon with the app closed at the same desk
    // are all still the same place. A night's sleep is not, and a flight
    // certainly isn't: restoring .beach onto somebody who has since flown home
    // is worse than restoring nothing, because the dwell window means they hear
    // the wrong playlist for dwellDuration before the detector can talk us out
    // of it. Six hours is about the longest gap that still reads as "same
    // place" more often than not.
    //
    // Note this is really governing the confirmed context alone. Debt expires
    // far sooner under its own rules — it decays over debtAccumulationDuration,
    // so any balance is at zero within minutes of the app going away, cutoff or
    // no cutoff.
    let maximumRestoreAge: TimeInterval
    static let defaultMaximumRestoreAge: TimeInterval = 6 * 60 * 60
    static let stateDefaultsKey = "contextDetectorState"

    // Speeds above this (m/s) count as "actively traveling" — roughly a slow walk.
    private let movementSpeedThreshold: CLLocationSpeed = 0.5

    // Source of current weather conditions; nil disables weather overrides.
    @ObservationIgnored private let weatherProvider: WeatherProviding?

    // MARK: - State
    // The only signal a context switch travels on. There used to be an
    // onContextChange closure alongside it, and the trouble with a closure is
    // that somebody has to keep it fresh: ContentView's captured `songs`, so
    // every import made the capture stale and the view had to remember to
    // re-assign it. Observation is enough — an observer reads whatever it needs
    // at the moment the change lands, and there is no second place to update.
    // The move off @Published changed the delivery mechanism and nothing about
    // this contract: a switch is still announced by assigning here and by
    // nothing else.
    private(set) var confirmedContext: MusicContext
    private(set) var zones: [ContextClassifier.Zone] = []
    private(set) var contextScores: [MusicContext: Double] = [:]
    // Latest known weather bucket, refreshed each evaluation (heavily cached upstream)
    private(set) var latestWeather: ContextClassifier.Factors.Condition? = nil
    // Runtime debt per context, 0...ContextClassifier.maxDebt. Only contexts
    // with a nonzero balance are present.
    private(set) var debts: [MusicContext: Double] = [:]

    // Everything from here down is the state machine's own bookkeeping rather
    // than something a view reads, so it stays out of observation: the macro
    // would otherwise make every one of these an observable property and charge
    // registrar traffic for candidate churn that no body has ever looked at.
    // They remain private(set) where they were — tests read them directly, and
    // @ObservationIgnored has nothing to do with access control.
    @ObservationIgnored private(set) var candidateContext: MusicContext? = nil
    @ObservationIgnored private(set) var candidateSince: Date? = nil
    @ObservationIgnored private(set) var bufferedContext: MusicContext? = nil
    @ObservationIgnored private(set) var bufferExpiry: Date? = nil
    @ObservationIgnored private var lastDebtTick: Date? = nil
    @ObservationIgnored private var lastTickLocation: CLLocation? = nil

    // Weak because the app scope owns the provider and we only borrow it.
    // POIProviding is AnyObject-bound precisely so this can stay weak — a
    // non-class-bound existential has no reference for `weak` to zero out.
    // @ObservationIgnored on top of that: this is a dependency slot rather than
    // view state, and leaving it observable would hand the macro's generated
    // accessors a weak reference to wrap for no benefit at all.
    @ObservationIgnored private weak var poiProvider: (any POIProviding)? = nil

    // "Running" means our hook is installed on the provider — there is no timer
    // to hold any more. Kept separate from the hook itself because the provider
    // is weak and may already be gone by the time we're torn down.
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var lastSearchStarted: Date? = nil

    // Where the last successful search was centred, and what it handed back.
    // These two move together on purpose: the displacement gate is really
    // asking "am I still standing where the results I'm holding describe?",
    // so a baseline with no results behind it would mean nothing. A search
    // that fails therefore updates neither, and the next fix retries.
    //
    // Deliberately not persisted, unlike the state machine below. The gate's
    // question only means anything against a current fix, and after a relaunch
    // we have none until the provider delivers one — so a restored cache would
    // let the very first evaluation of a new process be answered entirely from
    // disk and skip the search, at the one moment we most want ground truth.
    // Leaving them nil means the first evaluation always searches, which is the
    // behaviour start() was written for.
    @ObservationIgnored private var lastSearchLocation: CLLocation? = nil
    @ObservationIgnored private var lastSearchPlaces: [MKMapItem]? = nil

    // Where persisted state goes, and whether we've already taken it back out.
    // Restoring is once per instance: a stop()/start() cycle inside one process
    // has no gap to rehydrate across, and what's in memory is by definition at
    // least as fresh as the copy on disk.
    @ObservationIgnored private let store: any KeyValueStoring
    @ObservationIgnored private var hasRestoredState = false

    // Injectable clock for testability
    @ObservationIgnored var now: () -> Date = { Date() }

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
         maximumRestoreAge: TimeInterval = ContextDetector.defaultMaximumRestoreAge,
         store: any KeyValueStoring = UserDefaults.standard,
         weatherProvider: WeatherProviding?) {
        self.poiProvider = poiProvider
        self.confirmedContext = initialContext
        self.minimumSearchInterval = minimumSearchInterval
        self.minimumSearchDisplacement = minimumSearchDisplacement
        self.dwellDuration = dwellDuration
        self.searchRadius = searchRadius

        // `store` rather than `self.store`: the property isn't assigned yet, and
        // reading self before every stored property is initialised isn't
        // allowed. The parameter is the same object either way.
        let stored = store.double(forKey: Self.debtAccumulationDefaultsKey)
        let resolved = debtAccumulationDuration ?? (stored > 0 ? stored : Self.defaultDebtAccumulationDuration)
        self.debtAccumulationDuration = resolved > 0 ? resolved : Self.defaultDebtAccumulationDuration
        self.switchBufferDuration = switchBufferDuration
        self.maximumRestoreAge = maximumRestoreAge
        self.store = store
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

        // Rehydrate before anything else in here. Two callers depend on the
        // ordering: the evaluate() below, which would otherwise walk a state
        // machine that's about to be overwritten underneath it, and ContentView,
        // which reads confirmedContext immediately after this call to decide
        // what the launch queue should be — onChange(of:) never fires for an
        // initial value, so start() returning is the only moment a restored
        // context can be handed over.
        if !hasRestoredState {
            hasRestoredState = true
            restoreState()
        }

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

        // Signposted separately from the automatic path, and named so a trace can
        // tell them apart. A manual refresh is the one search that is allowed to
        // ignore both gates, so in an Instruments run it is the search that has an
        // obvious excuse — mixing it in with the automatic ones would inflate the
        // very number the gates exist to bring down.
        let searchState = Log.poiSearch.beginInterval("POI Search (Manual)",
                                                      id: Log.poiSearch.makeSignpostID())

        // Same off-main completion and the same deliberate hop as evaluate() — and
        // the same known capture diagnostic, for the same reason. See there.
        poiProvider.getPointsOfInterest(
            radius: searchRadius,
            filter: Array(ContextClassifier.categoryMap.keys)
        ) { [weak self] result in
            // Ended before the guard, not after it. The guard has two ways to
            // return — a deallocated detector and a failed search — and an
            // interval that is only closed on the success path is worse than no
            // interval at all, because Instruments draws an unterminated one as
            // running until the end of the trace. Closing here also makes the
            // interval mean exactly one thing: how long MapKit took.
            Log.poiSearch.endInterval("POI Search (Manual)", searchState)

            guard let self = self, case .success(let places) = result else { return }
            DispatchQueue.main.async {
                // Every exit from here has moved something worth keeping — the
                // early return below still cleared the buffer on its way past.
                defer { self.persistState() }

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
                // The early return earns its keep now that the assignment is
                // the whole signal, and moving to @Observable did not soften
                // that: withMutation fires on every write, equal or not, just
                // as @Published did, so writing the same context back would
                // still invalidate every observing view to say nothing.
                guard observed != self.confirmedContext else { return }
                self.confirmedContext = observed
                // .notice, like its twin in process(). A switch is the entire
                // output of this type and it is rare — gated by dwell, or by
                // somebody deliberately tapping a button, as here. It is also the
                // only line in the app that answers "why did the music change",
                // and that question is usually asked hours later, which rules out
                // the two levels that don't reach the disk.
                Log.context.notice("ContextDetector: manual refresh switched context to \(observed.displayName, privacy: .public)")
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
    // Main thread only: it writes observable state directly on the gated path.
    // Both callers oblige — start() runs on the app's main actor, and the
    // provider's callback comes off a CLLocationManager delegate created on
    // main.
    //
    // That second caller is also the answer to the off-main read this file was
    // flagged for. The detector used to sample the provider's currentLocation from
    // a repeating Timer, on whatever thread the timer had been scheduled on, while
    // the delegate wrote it on main — a read and a write of the same CLLocation
    // reference with nothing between them. LR-12 retired the clock in favour of the
    // delivery, so the read now happens *inside* the callback that just performed
    // the write, on the same thread, and the race went with it. Nothing was left to
    // fix here; the point is that the fix was structural and is easy to undo by
    // accident. Reintroducing any timer, queue or detached task that calls
    // evaluate() puts it straight back.
    //
    // Worth being plain that this is the delegate's guarantee and not the
    // compiler's: nothing in this type is @MainActor, so under strict concurrency
    // the compiler is taking this comment's word for all of it.
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
        //
        // latestWeather is observable state being written from a completion
        // handler, which is only alright because WeatherProviding promises the
        // completion arrives on main. That promise used to be kept by a hop the
        // provider made on the way *out*; it is now kept by the provider doing all
        // of its work on the main actor in the first place. Either way the burden
        // is on the provider — this closure does not hop, and must not be handed to
        // an implementation that doesn't keep the contract.
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
            // A signpost *event* for the search that didn't happen, and it is
            // the reason the signposting lives in this file rather than in
            // LocationHandler — see the long note on the interval below. A gated
            // pass is indistinguishable from an evaluation that never ran, so
            // without this the gate's saving shows up in a trace as an absence,
            // and an absence is exactly what a regression in the gate would look
            // like too. One event per skip turns "the searches got cheaper" into
            // "here are the searches we declined, and here is where you were
            // standing when we declined them".
            //
            // Only this gate gets an event, not the rate limit above it. The rate
            // limit returns before the state machine has advanced at all, so
            // nothing whatsoever happened on that pass and there is nothing to
            // attribute; it is also a fixed interval, so its saving is arithmetic
            // rather than a measurement. This gate is the one that depends on how
            // the user moved, which is the number nobody can predict from the
            // code.
            //
            // Deliberately carries no payload. The interesting quantity is the
            // count, and the only richer thing to say — how far short of the
            // threshold we fell — is a distance from the user's current position,
            // which is the one class of value this task agreed not to write down.
            Log.poiSearch.emitEvent("POI Search Skipped")
            apply(places: lastSearchPlaces, userLocation: location, speed: speed)
            return
        }

        // A search is only now actually starting, so this is where it starts
        // counting against the rate limit — a gated pass costs MapKit nothing
        // and shouldn't spend the budget.
        lastSearchStarted = evaluatedAt

        // The hop below is load-bearing and stays. POIProviding says outright that
        // results land on whatever queue the search finished on, so this closure is
        // the one place in the detector that genuinely starts off-main, and
        // everything it goes on to touch — the gate's baseline, the classifier
        // output, the state machine, the observable properties apply() writes — is
        // main-thread-only by the contract above evaluate().
        //
        // Known strict-concurrency diagnostic, deliberately left: DispatchQueue's
        // async takes a @Sendable closure, ContextDetector is a plain @Observable
        // class and therefore not Sendable, so capturing self here is reported.
        // The capture is safe for the reason the whole file rests on — one thread
        // touches this object — and the honest fixes both cost more than the
        // warning does. Marking the type @MainActor would have to reach start(),
        // refreshNow(), the tests that drive process() and tickDebt() directly, and
        // a deinit that cannot call main-actor methods at all; declaring the type
        // @unchecked Sendable would silence the compiler by asserting something
        // less true than what is written here.
        // The interval that makes the cost of location polling readable, and the
        // argument for putting it here rather than one layer down.
        //
        // LocationHandler.getPointsOfInterest is where MKLocalSearch actually
        // starts, so that looks like the obvious home for it, and it is the wrong
        // one for three reasons. The first is the gate immediately above: a
        // skipped search never calls the provider at all, so an interval down
        // there can only ever describe the searches that ran. It would report a
        // gated build and an ungated one identically except for the count, and
        // leave you to infer the saving from a number that also moves when the
        // user simply walks less. Both halves of the story have to come off the
        // same signposter to be comparable, and only one of the two files knows
        // both halves.
        //
        // The second is that the provider has an early return of its own — no
        // current location, no search — so an interval opened on entry there
        // would sometimes wrap nothing and drag the mean down. The third is that
        // POIProviding exists to be stubbed, and an interval attached to the
        // protocol's caller measures the seam the app actually runs on rather
        // than one particular implementation of it.
        //
        // What this measures is therefore "how long from the detector asking to
        // the detector being answered", which includes the provider's own region
        // arithmetic and dispatch. That is deliberate: the question being
        // profiled is what one evaluation costs, not what MapKit costs.
        let searchState = Log.poiSearch.beginInterval("POI Search",
                                                      id: Log.poiSearch.makeSignpostID())

        poiProvider.getPointsOfInterest(
            radius: searchRadius,
            filter: Array(ContextClassifier.categoryMap.keys)
        ) { [weak self] result in
            // First statement in the closure, ahead of the guard and outside the
            // switch, so that all three exits — a deallocated detector, a
            // success and a failure — close it. An interval left open is drawn
            // as still running for the remainder of the trace, which would make
            // a torn-down detector look like the most expensive search in the
            // run. Static, so it needs no self and survives the guard below.
            Log.poiSearch.endInterval("POI Search", searchState)

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
                //
                // .error even though the code above treats it as survivable, and
                // the two are not in tension: the recovery is automatic, but the
                // failure is still the reason the context stopped tracking, and
                // it is swallowed here and nowhere else. If searches are failing
                // steadily — a revoked MapKit entitlement, no network — the app
                // just quietly stops detecting anything, and this line is the
                // only place that ever says so.
                Log.context.error("ContextDetector POI search failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // Push one set of places through the classifier and into the state machine.
    // Shared by the fresh-search path and the displacement-gated re-score so
    // the two are identical in everything except where the places came from.
    // Main thread only: writes observable state.
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
        // Unconditional, including the priming tick that returns below: the
        // saved timestamp is how long we were gone, not how long since a
        // balance last moved, so it has to be rewritten whenever we look.
        defer { persistState() }
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
        // Covers all three exits. The candidate-only paths write nothing we
        // keep — dwell deliberately doesn't survive a launch — but the first
        // exit can still have retired an expired buffer inside isBuffered(),
        // and every exit refreshes the timestamp. See persistState().
        defer { persistState() }

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
            // The headline event of the whole app, and rare by construction —
            // nothing reaches this line without clearing the dwell window. See
            // the twin in refreshNow() for why .notice and why the name is
            // readable in release.
            Log.context.notice("ContextDetector: switched context to \(observedContext.displayName, privacy: .public)")
        }
    }

    // MARK: - Persistence
    //
    // What survives a relaunch, and — more interestingly — what doesn't.
    //
    // Kept:
    // - confirmedContext, because it is the whole output of this type and the
    //   thing the user hears. Losing it drops the music back to .all on every
    //   relaunch, which is the abrupt reshuffle this task exists to stop.
    // - debts, because debt is an accumulated *history*: an hour of walking
    //   past restaurants is exactly the evidence that stops restaurants owning
    //   the rest of the walk, and throwing it away hands them the city back.
    // - the switch buffer, because it's an absolute deadline rather than a
    //   duration. Being killed inside its window is the worst possible moment
    //   to forget it — start() evaluates immediately, sees the context we just
    //   left, and flaps straight back into the thing the buffer was armed to
    //   prevent. The expiry is already a Date, so serving out the remainder of
    //   the sentence costs one field.
    //
    // Not kept:
    // - candidateContext / candidateSince. candidateSince is a claim that we
    //   have been watching one context *continuously* since then, and a process
    //   that wasn't running watched nothing at all. Restoring it would let a
    //   candidate that was 29 seconds old when we died promote itself on the
    //   first evaluation after a relaunch hours later and a city away: a stale
    //   half-measurement, taken against a location the user has left, cashed in
    //   as a confirmed switch with no dwell actually served. It is the one piece
    //   of state whose entire meaning is "uninterrupted", and it costs 30
    //   seconds to re-earn honestly.
    // - LR-21's search cache — see lastSearchLocation for why.
    // - zones, contextScores and latestWeather, which are derived display state
    //   that the first evaluation recomputes anyway.
    //
    // savedAt is the freshness of the *observation*, not of the values, which is
    // why every transition rewrites it even when nothing in it changed. That's
    // what makes the age computed on restore mean "how long were we gone"
    // rather than "how long since the context last changed" — and for someone
    // who has sat in the same cafe all afternoon those are very different
    // numbers, with only the first one being any of our business.

    // Format version of the blob below, bumped whenever a blob written by an
    // older build stops meaning what this one would read it as.
    //
    // 1 is the first version, and LR-15 is why it exists. This state used to
    // hold MusicContext *display* strings — "Gyms" — because those were the
    // on-disk spelling everywhere. They're storage keys now, and a blob written
    // by a pre-LR-15 build would otherwise decode perfectly and restore
    // nonsense: every raw value failing to map, so the confirmed context
    // silently reverts to the launch default and the debt ledger comes back
    // empty, while savedAt and bufferExpiry sail through looking authoritative.
    // A half-restore that reports success is worse than no restore.
    //
    // So this field is the thing that turns "the strings changed underneath us"
    // into a fact the code can see. An old blob has no version key at all,
    // decoding fails on it, and restoreState throws the whole thing away and
    // starts clean — see there for what the user loses.
    //
    // It should not need bumping again for a rename: the keys are frozen now
    // (@NOTE in MusicContext.swift), which is the same guarantee Song.locations
    // just bought. It's here for the next *shape* change to this struct.
    static let persistedStateVersion = 1

    private struct PersistedState: Codable {
        // Storage keys rather than the enum, because MusicContext isn't Codable
        // and its keys are already the on-disk spelling everywhere else. Adding
        // a context is safe here — an unrecognised key is dropped on the way
        // back in rather than failing the whole restore — and renaming one is
        // no longer a thing anybody can do by accident.
        let version: Int
        let confirmedContext: String
        let debts: [String: Double]
        let bufferedContext: String?
        let bufferExpiry: Date?
        let savedAt: Date
    }

    // Cheap enough to run on every state transition: a few dozen bytes into
    // UserDefaults' in-memory cache, at most twice per accepted fix, and fixes
    // are already floored at minimumSearchInterval.
    private func persistState() {
        let state = PersistedState(
            version: Self.persistedStateVersion,
            confirmedContext: confirmedContext.storageKey,
            debts: debts.reduce(into: [String: Double]()) { $0[$1.key.storageKey] = $1.value },
            bufferedContext: bufferedContext?.storageKey,
            bufferExpiry: bufferExpiry,
            savedAt: now()
        )
        guard let encoded = try? JSONEncoder().encode(state) else { return }
        store.set(encoded, forKey: Self.stateDefaultsKey)
    }

    // Called once, from start(), rather than from init: `now` is injected after
    // construction, so a restore that ran in the initialiser could only ever
    // read the real clock and no test could drive it.
    private func restoreState() {
        guard let encoded = store.data(forKey: Self.stateDefaultsKey) else { return }

        // A blob we can't read, or one written in a format that predates the
        // current spelling, is discarded whole rather than salvaged in part.
        //
        // The pre-LR-15 blob is the case this was written for, and it's worth
        // being clear about the cost: on the first launch after upgrading, the
        // detector forgets where the user was and starts from the launch default
        // with an empty debt ledger. That is one dwell window of the wrong
        // playlist — annoying, bounded, and self-correcting the moment location
        // arrives. Translating the old display strings instead would mean a
        // second frozen copy of the migration's map living in this file forever,
        // to buy back thirty seconds, once, per user. Not worth it.
        //
        // Cleared rather than merely ignored, same as the staleness path below:
        // a blob this build will never accept shouldn't be re-read and
        // re-rejected on every launch until something happens to overwrite it.
        guard let saved = try? JSONDecoder().decode(PersistedState.self, from: encoded),
              saved.version == Self.persistedStateVersion else {
            store.removeObject(forKey: Self.stateDefaultsKey)
            return
        }

        // Wall clock is the only clock that survives a process, so this is also
        // the only place a user rewinding their device time can confuse us. A
        // negative age means they did — discard rather than try to reason about
        // it, same as anything else too old to trust.
        let age = now().timeIntervalSince(saved.savedAt)
        guard age >= 0, age <= maximumRestoreAge else {
            store.removeObject(forKey: Self.stateDefaultsKey)
            return
        }

        // Leaves initialContext in place if the key no longer maps — which now
        // only happens if a context was *removed* from the enum, the version
        // check above having taken care of the case where they were all respelt.
        if let restored = MusicContext(storageKey: saved.confirmedContext) {
            confirmedContext = restored
        }

        debts = saved.debts.reduce(into: [MusicContext: Double]()) { result, entry in
            guard let context = MusicContext(storageKey: entry.key), entry.value > 0 else { return }
            result[context] = min(entry.value, ContextClassifier.maxDebt)
        }

        // Only worth restoring if there is sentence left to serve.
        if let key = saved.bufferedContext, let expiry = saved.bufferExpiry,
           let buffered = MusicContext(storageKey: key), now() < expiry {
            bufferedContext = buffered
            bufferExpiry = expiry
        }

        // Charge the whole gap to the debt clock as time spent *not moving*.
        // Debt only accrues for a confirmed context whose user is walking, and a
        // suspended process watched nobody walk anywhere — so unobserved time
        // can pay debt down but must never build it. Handing the existing tick
        // the old timestamp does exactly that, with the same arithmetic every
        // other decay uses, and picks up the "release the buffer once its debt
        // drains" rule on the way through for free.
        lastDebtTick = saved.savedAt
        tickDebt(isMoving: false)
    }
}
