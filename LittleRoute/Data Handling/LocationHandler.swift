import Foundation
import CoreLocation
import MapKit
import Observation
import os

// Points of interest reference
// https://developer.apple.com/documentation/mapkit/mkpointofinterestcategory

// POIProviding is the two-member slice ContextDetector talks to; the members
// below already satisfy it, so conforming here costs nothing and lets the
// detector be built against a stub instead of a real CLLocationManager.
@Observable
class LocationHandler: NSObject, CLLocationManagerDelegate, POIProviding {
    // MARK: - Properties
    @ObservationIgnored private let locationManager = CLLocationManager()

    // Both of these are genuine view state, so they stay observable. The note
    // that used to sit here told you to keep the list short, because ContentView
    // observed the whole object just to read authorizationStatus and so anything
    // published alongside it re-invalidated that body. @Observable is what
    // retired that constraint: SwiftUI now tracks the individual properties a
    // body actually read, so currentLocation churning on every accepted fix
    // costs a view that only reads authorizationStatus nothing at all.
    var authorizationStatus: CLAuthorizationStatus? = nil
    var currentLocation: CLLocation? = nil

    // Deliberately @ObservationIgnored -- it's a callback slot, not view state.
    // ContextDetector hangs its entire detection pass off this; see the note in
    // didUpdateLocations for why delivery rather than a clock drives detection.
    @ObservationIgnored var onLocationUpdate: ((CLLocation) -> Void)? = nil

    // Throttling: accept a new location only after this much time has passed
    // since the last accepted update, or when the user has moved farther than
    // the distance threshold. Saves battery and avoids redundant POI churn.
    //
    // This stayed in software through LR-24 rather than moving onto the manager's
    // distanceFilter, and the *time* arm is the load-bearing half -- see the long
    // note on distanceFilter in init() before deleting it in the name of battery.
    // The distance arm is really just a fast path for vehicles: you have to be
    // covering better than 400m/60s (~24km/h) for it to fire before the clock does.
    @ObservationIgnored private let updateInterval: TimeInterval = 60
    @ObservationIgnored private let significantDistance: CLLocationDistance = 400
    @ObservationIgnored private var lastAcceptedLocation: CLLocation? = nil
    @ObservationIgnored private var lastAcceptedTime: Date? = nil
    
    // iOS shows the "keep using in the background?" upgrade prompt exactly once per
    // install, so this stops us re-asking every time the delegate fires. it does not
    // need to persist across launches -- a repeat call is a no-op at the OS level,
    // this just keeps us from spamming it within a session.
    @ObservationIgnored private var hasRequestedAlwaysUpgrade = false

    // Init. This used to ask for the maximum possible accuracy to tell close
    // buildings apart (hopefully); it no longer does, and the two properties
    // below carry most of LR-24 between them.
    override init() {
        super.init()
        locationManager.delegate = self

        // kCLLocationAccuracyBest pins the GPS chip in continuous full-power mode,
        // and we were buying precision that nothing downstream could spend. The
        // only numbers that decide anything: the smallest effectiveRadius in
        // ContextClassifier.profiles is 70m (restaurants), and ContextDetector's
        // displacement gate is 50m. A ten-metre fix is a seventh of the first and
        // a fifth of the second, so neither "am I inside this zone" nor "have I
        // moved far enough to buy a fresh search" changes its answer because of
        // the downgrade -- and 10m of noise stays comfortably under that 50m gate,
        // so drift still can't unlock a search on its own while you sit still.
        //
        // Ten metres is also the *coarsest* rung that holds. The next one down is
        // kCLLocationAccuracyHundredMeters, whose error is larger than the whole
        // restaurant radius and would swamp the gate twice over: drift alone would
        // start buying searches and flipping zone membership, which is precisely
        // what that gate was sized to prevent.
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters

        // ...and this one stays wide open, however much LR-24 wanted it closed.
        //
        // distanceFilter has no time arm. It fires on movement and on nothing
        // else, so any value above the noise floor delivers a genuinely stationary
        // user exactly zero fixes. The software throttle below cannot paper over
        // that: a throttle *discards* events, it can't manufacture them, so the
        // moment the OS stops delivering there is nothing left to throttle and the
        // 60s arm never gets a turn.
        //
        // And stationary is the case that matters most here. ContextDetector runs
        // entirely off delivered fixes now (LR-12), its dwell window only closes on
        // an evaluation, and LR-21's displacement gate re-scores the cached places
        // rather than returning early for exactly this reason. Someone who has just
        // sat down inside a restaurant is precisely the person whose dwell is about
        // to complete and whose music is about to change. Starving them is the same
        // hole the poll timer left, reached by a third road -- and a Timer can't
        // plug it either, for the reason POIProviding spells out: it stops firing
        // the moment the app is suspended.
        //
        // So the wakeup filtering stays in didUpdateLocations and LR-24's battery
        // win comes out of desiredAccuracy above. Set explicitly rather than left
        // to the default because the next person to read LR-24 will come here to
        // "finish" it.
        // @TODO: if ~1Hz delivery really does show up in an Energy Log, the honest
        //        fix is a coarser filter *plus* a source that still reports while
        //        stationary -- CLLocationUpdate.liveUpdates() flags that state --
        //        never a bare distanceFilter.
        locationManager.distanceFilter = kCLDistanceFilterNone

        // the entire premise of this app is music that changes as you move, which
        // does not survive the screen going off: CoreLocation stops delivering the
        // moment we background, while the audio session happily keeps playing. this
        // is what keeps updates coming.
        // NB: this line *traps* if UIBackgroundModes in Info.plist is missing the
        //     `location` value -- it's a hard crash, not a polite failure, so the
        //     plist entry and this line have to move together.
        locationManager.allowsBackgroundLocationUpdates = true

        // and put the blue indicator in the status bar while we do it. we are
        // following you down the street; the least we can do is admit it.
        locationManager.showsBackgroundLocationIndicator = true

        // this one defaults to *true*, and it is load-bearing for detection now.
        // when iOS decides you've been stationary long enough it pauses updates,
        // which stops the delegate firing and lets the app suspend -- and it does
        // not resume on its own. that's the same hole the poll timer had, just
        // reached by a different road. ContextDetector is driven by delivery, so
        // a user who has sat down still needs fixes to keep arriving: that is
        // exactly when a dwell window is supposed to be finishing.
        // LR-24 has now had its go at accuracy/distanceFilter, and this line came
        // through it untouched: accuracy came down, the filter stayed open, pausing
        // stays off. Nothing about battery tuning makes re-enabling it the answer.
        locationManager.pausesLocationUpdatesAutomatically = false
    }
    
    // MARK: - Public Methods
    
    // Request authorization to use location services  
    //  might move this somewhere else, gotta see how it plays out bc I don't have my mac with me
    // this is deliberately still the *when in use* ask and nothing more. asking for
    // always straight out of a cold start does not work -- iOS quietly drops an
    // always-request made from .notDetermined, and we'd burn our one prompt for
    // nothing. the upgrade happens in locationManagerDidChangeAuthorization once
    // when-in-use is actually on the books.
    // @TODO: test the two-step prompt on a real device, the simulator fakes it
    public func requestLocationAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    // Step two: upgrade when-in-use to always, so location keeps arriving once the
    // screen locks. only ever called from the delegate after when-in-use is granted.
    // we get one shot at this prompt for the lifetime of the install, hence the flag
    // -- and if the user says no we just carry on with when-in-use, which still gets
    // us background updates while audio is playing, just more fragile ones.
    private func requestAlwaysUpgradeIfNeeded() {
        guard !hasRequestedAlwaysUpgrade else { return }
        hasRequestedAlwaysUpgrade = true
        locationManager.requestAlwaysAuthorization()
    }

    /// Start updating location
    public func startLocationUpdates() {
        locationManager.startUpdatingLocation()
    }
    
    // Stop updating location(?) unsure if necessary bc we should always have it enabled while running
    // maybe switch on and off based on user being stationary for saving battery? future consideration to make ig
    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
    }
    
    // Get the current location if available
    public func getCurrentLocation() -> CLLocation? {
        return currentLocation
    }

    public func getPointsOfInterest(radius: CLLocationDistance, filter: [MKPointOfInterestCategory]? = nil, completion: @escaping (Result<[MKMapItem], Error>) -> Void) {
        guard let currentLocation = currentLocation else {
            completion(.success([]))
            return
        }

        // Build a region centered on current coordinate. MKCoordinateRegion
        // takes the full *span*, not a radius, so the doubling here is a unit
        // conversion: a square of side 2r circumscribes the circle of radius r
        // we actually want covered. `radius` used to arrive pre-doubled from
        // ContextClassifier on top of this, which made the query a 2.4km
        // square -- and since MKLocalSearch caps its result count, the extra
        // reach only diluted the sample. That doubling is gone; this one
        // stays.
        let region = MKCoordinateRegion(
            center: currentLocation.coordinate,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )

        let request = MKLocalSearch.Request()
        request.region = region
        if let filter = filter {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: filter)
        } else {
            // If no explicit categories provided, restrict to POIs by providing an empty excluding filter
            // so we don't get generic search results that aren't actual POIs
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: MKPointOfInterestCategory.allCases)
        }

        let search = MKLocalSearch(request: request)
        // Known strict-concurrency diagnostic, deliberately left: MapKit hands this
        // block back on whatever queue finished the search, so `completion` — an
        // ordinary escaping closure, not a @Sendable one — gets captured across a
        // boundary the compiler is entitled to object to. Annotating the parameter
        // @Sendable would only move the complaint next door, onto ContextDetector's
        // [weak self] closures at both call sites, which are non-Sendable for the
        // reasons set out there. The queue this lands on is documented on
        // POIProviding precisely so callers know to hop, and both of them do.
        search.start { (response: MKLocalSearch.Response?, error: Error?) in
            if let error = error {
                completion(.failure(error))
                return
            }
            // results go to the caller only -- we deliberately don't stash them on
            // the handler, that used to republish on every poll for nobody's benefit
            completion(.success(response?.mapItems ?? []))
        }
    }

    // MARK: - CLLocationManagerDelegate
    //
    // Everything in this section writes observable state without hopping, and is
    // right to. CLLocationManager delivers to the run loop of the thread it was
    // created on; this one is created in init(), which runs from LittleRouteApp's
    // initialiser on the main thread, so every callback below is a main-thread
    // callback. That single fact is what the detector's whole main-thread contract
    // is anchored to — didUpdateLocations calls straight into ContextDetector,
    // which writes observable state of its own and never hops either.
    //
    // Which makes it worth saying where it could break: constructing a
    // LocationHandler off the main thread would silently move every delegate
    // callback with it, and nothing in the type would notice. Nothing does that
    // today — the app builds exactly one, in App.init — and a test that built one
    // on a background queue would be the first.
    //
    // checks if the user disabled location permissions, and drives the second half
    // of the two-step authorization dance (when-in-use -> always). this fires once
    // on delegate assignment with whatever we already had, so an existing install
    // that only granted when-in-use gets offered the upgrade on next launch.
    // The `**ERROR:` prefixes these four lines used to carry are gone, and that
    // is not tidying. They were a level field written by hand, because print has
    // no level field; Logger does, so keeping them would say the same thing
    // twice — and in the .notDetermined case it said it wrongly. Waiting for the
    // user to answer a prompt we have only just put in front of them is the
    // normal opening state of every first launch, not a fault. The substance of
    // each message is otherwise untouched.
    //
    // The two grants are .info: they happen about once per launch, they are the
    // first thing anyone checks when location isn't working, and .info survives
    // into a sysdiagnose whereas .debug does not.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            Log.location.info("location auth granted successfully (when in use)")
            // now, and only now, is the always-prompt worth spending -- iOS will
            // actually show it once when-in-use is already granted.
            requestAlwaysUpgradeIfNeeded()
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
            Log.location.info("location auth granted successfully (always)")
        case .denied, .restricted:
            // .error, because this one really is fatal to the premise: with no
            // authorization there are no fixes, with no fixes there is no
            // detection, and every other diagnostic downstream of here will be
            // silence that looks like a different bug.
            // @TODO: create screen that requests user to grant authorization to continue using the app
            Log.location.error("location auth failed/not granted!")
        case .notDetermined:
            // Wait for user to make a choice
            Log.location.debug("awaiting user location auth")
        @unknown default:
            break
        }
    }
    
    // create manager with past locations. unsure if necessary yet depending on how geofences/contexts get implemented
    // need to come back to this and share context enums from the music playback branch
    // https://developer.apple.com/documentation/mapkit/mkpointofinterestcategory
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Throttle: only accept the update if 60s have passed since the last
        // accepted one, or the user moved more than 400m. The first update is
        // always accepted.
        //
        // Same rule as it always was, just written as a rejection so the two arms
        // can short-circuit. Since distanceFilter stays open we run this ~60 times
        // for every fix we actually keep, and distance(from:) is a haversine --
        // reading the clock first means the 59 we're about to throw away don't each
        // pay for the trig. This is the cheap half of "stop doing work per wakeup";
        // the expensive half was the GPS mode, and that's handled in init().
        if let lastLocation = lastAcceptedLocation, let lastTime = lastAcceptedTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < updateInterval,
               location.distance(from: lastLocation) <= significantDistance {
                return
            }
        }

        lastAcceptedLocation = location
        lastAcceptedTime = Date()

        currentLocation = location

        // and this is what actually drives context detection. delegate callbacks
        // arrive on the queue the manager was created on -- main, here -- so the
        // detector gets a main-thread call and doesn't have to hop.
        //
        // note the throttle above has a *time* arm as well as a distance one, so
        // standing perfectly still still produces a fix every updateInterval.
        // that matters: the detector's dwell window can only close on an
        // evaluation, and the user who has stopped walking is precisely the one
        // whose dwell should be completing.
        onLocationUpdate?(location)
    }


    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // this used to land in a published var nobody read, which is a fancy way of
        // saying it vanished, and then in a print, which meant it only existed while
        // Xcode was attached. It now goes somewhere that keeps it.
        //
        // .error is the level with the worst spam risk here and still the right one.
        // kCLErrorLocationUnknown is genuinely transient — the fix just isn't ready
        // yet — and .error is persisted, so a run of them takes up room. But the
        // alternative buries a denied-while-running or a heading failure under the
        // same silence this line was written to end, and this delegate method is not
        // called per fix, only per failure.
        // @TODO: split kCLErrorLocationUnknown down to .debug and leave the rest here,
        //        and decide separately whether the user ever needs to see any of it
        Log.location.error("location manager failed -- \(error.localizedDescription, privacy: .public)")
    }
}

// @TODO: fix this bs, this is just temporary until i get a build working
//        also inefficient as hell
//        grouping these together for future reference  
extension MKPointOfInterestCategory {
    static var allCases: [MKPointOfInterestCategory] {
        // Build in chunks to help the type-checker
        let aquatic: [MKPointOfInterestCategory] = [
            .aquarium, .beach, .marina, .fishing, .kayaking, .surfing, .swimming
        ]
        let sports: [MKPointOfInterestCategory] = [
            .baseball, .basketball, .bowling, .golf, .fitnessCenter, .stadium, .tennis, .skiing, .soccer, .stadium, .tennis, .volleyball
        ]
        let dining: [MKPointOfInterestCategory] = [
            .bakery, .brewery, .cafe, .distillery, .foodMarket, .restaurant, .winery
        ]
        let parks: [MKPointOfInterestCategory] = [
            .amusementPark, .campground, .fairground, .landmark, .nationalPark, .park, .rvPark
        ]
        let nightlife: [MKPointOfInterestCategory] = [
            .miniGolf, .movieTheater, .musicVenue, .nightlife, .park, .parking, .pharmacy, .police, .postOffice
        ]
        let city: [MKPointOfInterestCategory] = [
            .airport, .conventionCenter, .publicTransport, .hotel
        ]
        let education: [MKPointOfInterestCategory] = [
            .library, .museum, .nationalMonument,.planetarium, .school, .theater, .university, .zoo
        ]
        /*
        let markets: [MKPointOfInterestCategory] = [
            .groceryStore, .shoppingCenter, .store
        ]
        let rural: [MKPointOfInterestCategory] = [
            .landmark, .naturalFeature
        ]
        let other: [MKPointOfInterestCategory] = [
            .other
        ]
         */
        return aquatic + sports + dining + parks + nightlife + city + education // + markets + rural + other
    }
}

/*
// UNUSED:
.goKart
*/
