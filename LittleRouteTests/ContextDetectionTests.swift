//
//  ContextDetectionTests.swift
//  LittleRouteTests
//

import Testing
import Foundation
import MapKit
import CoreLocation
import WeatherKit
@testable import LittleRoute

struct ContextClassifierTests {

    @Test func mapsKnownCategoriesToContexts() {
        #expect(ContextClassifier.context(for: .beach) == .beach)
        #expect(ContextClassifier.context(for: .store) == .store)
        #expect(ContextClassifier.context(for: .fitnessCenter) == .gym)
        #expect(ContextClassifier.context(for: .restaurant) == .restaurant)
        #expect(ContextClassifier.context(for: .park) == .park)
        #expect(ContextClassifier.context(for: .airport) == .city)
    }

    @Test func unmappedCategoryReturnsNil() {
        #expect(ContextClassifier.context(for: .police) == nil)
        #expect(ContextClassifier.context(for: nil) == nil)
    }

    @Test func classifyReturnsNilWhenNoPlaces() {
        let result = ContextClassifier.classify(places: [], userLocation: CLLocation(latitude: 0, longitude: 0))
        #expect(result == nil)
    }

    @Test func classifyPicksOnlyPlaceWithinItsEffectiveRadius() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let far = mapItem(category: .beach, latitude: 0.01, longitude: 0.01)
        let near = mapItem(category: .store, metersEast: 60)

        let result = ContextClassifier.classify(places: [far, near], userLocation: user)
        #expect(result == .store)
    }

    @Test func largerContextCanOutscoreCloserCommonPlace() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let park = mapItem(category: .park, metersEast: 150)
        let restaurant = mapItem(category: .restaurant, metersEast: 50)

        let evaluation = ContextClassifier.evaluate(places: [restaurant, park], userLocation: user)

        #expect(evaluation.context == .park)
        #expect(evaluation.scores[.park, default: 0] > evaluation.scores[.restaurant, default: 0])
    }

    @Test func placesOutsideEffectiveRadiusRemainVisibleButDoNotScore() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let restaurant = mapItem(category: .restaurant, metersEast: 75)

        let evaluation = ContextClassifier.evaluate(places: [restaurant], userLocation: user)

        #expect(evaluation.context == nil)
        #expect(evaluation.scores.isEmpty)
        #expect(evaluation.zones.count == 1)
        #expect(evaluation.zones.first?.score == 0)
    }

    @Test func contextProfilesUseDifferentEffectiveRadii() {
        let parkRadius = ContextClassifier.profile(for: .park)?.effectiveRadius
        let restaurantRadius = ContextClassifier.profile(for: .restaurant)?.effectiveRadius

        #expect(parkRadius != nil)
        #expect(restaurantRadius != nil)
        #expect(parkRadius! > restaurantRadius!)
    }

    @Test func searchRadiusCoversTheWidestProfileWithoutOvershooting() {
        let widest = ContextClassifier.profiles.values.map(\.effectiveRadius).max()
        #expect(widest == 600)

        // Anything further out than the widest profile scores zero by
        // construction, so asking for it is wasted reach. This used to be
        // double the figure below, and LocationHandler doubled it again into a
        // 2.4km span — and because MKLocalSearch caps its result set, the
        // surplus bought a thinner sample of a bigger area rather than more
        // coverage of the right one.
        #expect(ContextClassifier.searchRadius == widest)
    }

    @Test func specificityRanksUncommonContextsAboveCommonOnes() {
        let beach = ContextClassifier.profile(for: .beach)?.specificity
        let gym = ContextClassifier.profile(for: .gym)?.specificity
        let restaurant = ContextClassifier.profile(for: .restaurant)?.specificity

        #expect(beach! > gym!)
        #expect(gym! > restaurant!)
        #expect(restaurant! < 1.0)
        #expect(beach! > 1.0)
    }

    @Test func debtDiscountsAnOtherwiseWinningContext() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let restaurant = mapItem(category: .restaurant, metersEast: 10)
        let store = mapItem(category: .store, metersEast: 40)

        let clean = ContextClassifier.evaluate(places: [restaurant, store], userLocation: user)
        #expect(clean.context == .restaurant)
        #expect(clean.contextIgnoringDebt == .restaurant)

        let indebted = ContextClassifier.evaluate(
            places: [restaurant, store],
            userLocation: user,
            debts: [.restaurant: ContextClassifier.maxDebt]
        )
        #expect(indebted.context == .store)
        // The debt-free view still favors the restaurant — that disagreement is
        // what flags the switch as debt-driven.
        #expect(indebted.contextIgnoringDebt == .restaurant)
    }

    @Test func debtAloneCannotForceASwitchWithoutACompetingZone() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let restaurant = mapItem(category: .restaurant, metersEast: 10)

        let evaluation = ContextClassifier.evaluate(
            places: [restaurant],
            userLocation: user,
            debts: [.restaurant: ContextClassifier.maxDebt]
        )

        // Even fully indebted, the only present context still wins.
        #expect(evaluation.context == .restaurant)
        #expect(evaluation.scores[.restaurant, default: 0] > 0)
    }

    @Test func debtMultiplierIsClampedAndNeverZeroesAContext() {
        #expect(ContextClassifier.debtMultiplier(for: 0) == 1.0)
        #expect(ContextClassifier.debtMultiplier(for: ContextClassifier.maxDebt) == 1.0 - ContextClassifier.maxDebt)
        #expect(ContextClassifier.debtMultiplier(for: 99) == 1.0 - ContextClassifier.maxDebt)
        #expect(ContextClassifier.debtMultiplier(for: -5) == 1.0)
        #expect(ContextClassifier.debtMultiplier(for: 99) > 0)
    }

    // MARK: Zone identity

    // Locally built map items carry no MapKit identifier, so these exercise the
    // coordinate fallback — the path that used to churn.
    @Test func zoneIDSurvivesCoordinateDriftForTheSamePlace() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let firstPoll = mapItem(category: .restaurant, metersEast: 60, name: "Rosa's")
        // the same place, nudged half a metre by a fresh search
        let secondPoll = mapItem(category: .restaurant, metersEast: 60.5, name: "Rosa's")

        let first = ContextClassifier.evaluate(places: [firstPoll], userLocation: user)
        let second = ContextClassifier.evaluate(places: [secondPoll], userLocation: user)

        #expect(first.zones.first?.id == second.zones.first?.id)
    }

    @Test func distinctPlacesTwentyMetresApartKeepDistinctZoneIDs() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let rosas = mapItem(category: .restaurant, metersEast: 0, name: "Rosa's")
        let hanks = mapItem(category: .restaurant, metersEast: 20, name: "Hank's")

        let evaluation = ContextClassifier.evaluate(places: [rosas, hanks], userLocation: user)

        #expect(evaluation.zones.count == 2)
        #expect(evaluation.zones[0].id != evaluation.zones[1].id)
    }

    // Two units of the same building round into one grid cell — the name is what
    // has to keep them apart there.
    @Test func neighborsInsideOneGridCellAreSplitByName() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let bakery = mapItem(category: .bakery, metersEast: 30, name: "Unit A")
        let cafe = mapItem(category: .cafe, metersEast: 32, name: "Unit B")

        let evaluation = ContextClassifier.evaluate(places: [bakery, cafe], userLocation: user)

        #expect(evaluation.zones.count == 2)
        #expect(evaluation.zones[0].id != evaluation.zones[1].id)
    }

    // MARK: External factors — weather
    //
    // Weather used to be a hard override: any rain at all returned .rainy ahead
    // of speed and ahead of every POI. It now scores instead, so these read as
    // "how strong a claim does the place have?" rather than "is it raining?".

    // The spec's first case: an indoor context with a strong POI score survives
    // rain. Standing in the gym doorway, 10m from the pin on a 120m radius,
    // scores 0.96 — comfortably past the weather's flat 0.5.
    @Test func strongIndoorPOISurvivesRain() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let gym = mapItem(category: .fitnessCenter, metersEast: 10)
        let factors = ContextClassifier.Factors(weather: .rainy, speed: 1.5)

        let evaluation = ContextClassifier.evaluate(places: [gym], userLocation: user, factors: factors)

        #expect(evaluation.context == .gym)
        #expect(evaluation.contextIgnoringDebt == .gym)
        // the rain is still on the board, just outscored
        #expect(evaluation.scores[.rainy, default: 0] == ContextClassifier.weatherScore)
    }

    // The same for the least specific context we recognise: sitting in a
    // restaurant in a snowstorm, the restaurant still exists.
    @Test func sittingInARestaurantSurvivesSnow() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let restaurant = mapItem(category: .restaurant, metersEast: 5)
        let factors = ContextClassifier.Factors(weather: .snowy, speed: 0)

        let evaluation = ContextClassifier.evaluate(places: [restaurant], userLocation: user, factors: factors)
        #expect(evaluation.context == .restaurant)
    }

    // The spec's second case, and what the feature is actually for: nothing
    // around with a real claim, so the weather takes it.
    @Test func openGroundInRainSelectsRainy() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let factors = ContextClassifier.Factors(weather: .rainy, speed: 1.5)

        let evaluation = ContextClassifier.evaluate(places: [], userLocation: user, factors: factors)

        #expect(evaluation.context == .rainy)
        #expect(evaluation.contextIgnoringDebt == .rainy)
        #expect(evaluation.zones.isEmpty) // weather is not a place, so it draws no zone
    }

    @Test func openGroundInSnowSelectsSnowy() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let evaluation = ContextClassifier.evaluate(
            places: [],
            userLocation: user,
            factors: ContextClassifier.Factors(weather: .snowy, speed: 1.5)
        )
        #expect(evaluation.context == .snowy)
    }

    // Between the two: a restaurant 50m away on a 70m radius scores 0.20, which
    // is a place you are walking past rather than one you are in.
    @Test func weaklyClaimedGroundLosesToRain() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let restaurant = mapItem(category: .restaurant, metersEast: 50)
        let factors = ContextClassifier.Factors(weather: .rainy, speed: 1.5)

        let evaluation = ContextClassifier.evaluate(places: [restaurant], userLocation: user, factors: factors)

        #expect(evaluation.context == .rainy)
        // the restaurant is still scored and still drawn — it just lost
        #expect(evaluation.scores[.restaurant, default: 0] > 0)
        #expect(evaluation.zones.count == 1)
    }

    // Damping: an open-air context is worth less when the sky is against it, so
    // a beach that wins on a clear day can lose the same spot in the rain.
    @Test func rainDampsOpenAirContextsEnoughToChangeTheWinner() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let beach = mapItem(category: .beach, metersEast: 300) // 0.65 clear, 0.39 wet

        let clear = ContextClassifier.evaluate(
            places: [beach], userLocation: user,
            factors: ContextClassifier.Factors(weather: .clear, speed: 1.5)
        )
        #expect(clear.context == .beach)

        let wet = ContextClassifier.evaluate(
            places: [beach], userLocation: user,
            factors: ContextClassifier.Factors(weather: .rainy, speed: 1.5)
        )
        #expect(wet.context == .rainy)
        #expect(wet.scores[.beach, default: 0] < clear.scores[.beach, default: 0])
    }

    // ...but damping never zeroes a context out, so standing on the beach in
    // the rain is still the beach.
    @Test func dampingDoesNotEraseAContextYouAreStandingIn() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let beach = mapItem(category: .beach, metersEast: 100) // 1.08 clear, 0.65 wet

        let evaluation = ContextClassifier.evaluate(
            places: [beach], userLocation: user,
            factors: ContextClassifier.Factors(weather: .rainy, speed: 1.5)
        )
        #expect(evaluation.context == .beach)
    }

    @Test func weatherMultiplierSparesTheContextsWithARoof() {
        #expect(ContextClassifier.weatherMultiplier(for: .beach, in: .rainy) == ContextClassifier.outdoorWeatherMultiplier)
        #expect(ContextClassifier.weatherMultiplier(for: .park, in: .snowy) == ContextClassifier.outdoorWeatherMultiplier)
        #expect(ContextClassifier.weatherMultiplier(for: .gym, in: .rainy) == 1.0)
        #expect(ContextClassifier.weatherMultiplier(for: .restaurant, in: .rainy) == 1.0)
        #expect(ContextClassifier.weatherMultiplier(for: .store, in: .rainy) == 1.0)
        // .city is mostly indoor venues, so the rain doesn't spoil it
        #expect(ContextClassifier.weatherMultiplier(for: .city, in: .rainy) == 1.0)
        // and fair weather touches nothing at all
        #expect(ContextClassifier.weatherMultiplier(for: .beach, in: .clear) == 1.0)
        #expect(ContextClassifier.weatherMultiplier(for: .beach, in: nil) == 1.0)
        #expect(ContextClassifier.outdoorWeatherMultiplier > 0) // never zeroes a context
    }

    // Weather is not a place: it has no profile, so it has no radius to widen
    // the POI search with and no specificity to weight it by. The flat
    // weatherScore stands in for both.
    @Test func weatherContextsHaveNoProfileAndDoNotWidenTheSearch() {
        #expect(!ContextClassifier.profiles.keys.contains(.rainy))
        #expect(!ContextClassifier.profiles.keys.contains(.snowy))
        #expect(ContextClassifier.searchRadius == 600)
        #expect(ContextClassifier.weatherContext(for: .rainy) == .rainy)
        #expect(ContextClassifier.weatherContext(for: .snowy) == .snowy)
        #expect(ContextClassifier.weatherContext(for: .clear) == nil)
        #expect(ContextClassifier.weatherContext(for: nil) == nil)
    }

    // weatherScore sits below what the least specific profile earns at full
    // proximity, which is the whole tuning argument: a place you are inside
    // beats the weather, a place you are near does not.
    @Test func weatherScoreSitsBelowTheLeastSpecificProfile() {
        let restaurant = ContextClassifier.profile(for: .restaurant)!.specificity
        #expect(ContextClassifier.weatherScore < restaurant)
        #expect(ContextClassifier.weatherScore > restaurant / 2)
    }

    // Because weather scores rather than overrides, debt applies to it like
    // anything else — and the debt-free view still disagrees, which is what
    // arms ContextDetector's anti-flap buffer. Under the old override both
    // views returned .rainy unconditionally and the buffer could never fire.
    @Test func rainAccumulatesDebtLikeAnyOtherContext() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let restaurant = mapItem(category: .restaurant, metersEast: 30) // scores 0.40
        let factors = ContextClassifier.Factors(weather: .rainy, speed: 1.5)

        let fresh = ContextClassifier.evaluate(places: [restaurant], userLocation: user, factors: factors)
        #expect(fresh.context == .rainy) // 0.50 beats 0.40

        let indebted = ContextClassifier.evaluate(
            places: [restaurant],
            userLocation: user,
            debts: [.rainy: ContextClassifier.maxDebt], // an hour of walking in it
            factors: factors
        )
        #expect(indebted.context == .restaurant) // 0.25 no longer does
        #expect(indebted.contextIgnoringDebt == .rainy)
    }

    // MARK: External factors — speed

    // Speed is the one hard override left, and it now sits above weather:
    // 60mph through a downpour is a car, not a rainstorm.
    @Test func speedBeatsRainAtHighwaySpeed() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let beach = mapItem(category: .beach, metersEast: 50)
        let factors = ContextClassifier.Factors(weather: .rainy, speed: 30) // raining AND highway speed

        let evaluation = ContextClassifier.evaluate(places: [beach], userLocation: user, factors: factors)

        #expect(evaluation.context == .traveling)
        #expect(evaluation.contextIgnoringDebt == .traveling)
        #expect(!evaluation.zones.isEmpty) // the map still gets its zones
        // and the weather doesn't even reach the scoreboard up there
        #expect(evaluation.scores[.rainy] == nil)
    }

    @Test func speedBeatsSnowAtHighwaySpeed() {
        let factors = ContextClassifier.Factors(weather: .snowy, speed: 30)
        #expect(ContextClassifier.contextOverride(for: factors) == .traveling)
    }

    // Below the threshold the weather is back in play — the override is speed's
    // alone, so bad weather at walking pace never reaches contextOverride.
    @Test func weatherIsNoLongerAHardOverride() {
        #expect(ContextClassifier.contextOverride(for: ContextClassifier.Factors(weather: .rainy, speed: 1.5)) == nil)
        #expect(ContextClassifier.contextOverride(for: ContextClassifier.Factors(weather: .snowy, speed: nil)) == nil)
    }

    @Test func speedAbove35mphClassifiesAsTraveling() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let beach = mapItem(category: .beach, metersEast: 50)
        let factors = ContextClassifier.Factors(weather: .clear, speed: 16) // ~36 mph

        let evaluation = ContextClassifier.evaluate(places: [beach], userLocation: user, factors: factors)
        #expect(evaluation.context == .traveling)
    }

    @Test func speedBelowThresholdDoesNotOverride() {
        let walking = ContextClassifier.Factors(weather: .clear, speed: 1.5)
        let driving33 = ContextClassifier.Factors(weather: .clear, speed: 15) // ~33.5 mph
        #expect(ContextClassifier.contextOverride(for: walking) == nil)
        #expect(ContextClassifier.contextOverride(for: driving33) == nil)
    }

    @Test func unknownFactorsDoNotOverride() {
        #expect(ContextClassifier.contextOverride(for: ContextClassifier.Factors()) == nil)

        let user = CLLocation(latitude: 0, longitude: 0)
        let beach = mapItem(category: .beach, metersEast: 50)
        let evaluation = ContextClassifier.evaluate(
            places: [beach],
            userLocation: user,
            factors: ContextClassifier.Factors(weather: .clear, speed: 1.5)
        )
        #expect(evaluation.context == .beach)
    }

    @Test func weatherKitConditionsBucketCorrectly() {
        #expect(WeatherKitProvider.bucket(.rain) == .rainy)
        #expect(WeatherKitProvider.bucket(.thunderstorms) == .rainy)
        #expect(WeatherKitProvider.bucket(.freezingRain) == .rainy)
        #expect(WeatherKitProvider.bucket(.snow) == .snowy)
        #expect(WeatherKitProvider.bucket(.blizzard) == .snowy)
        #expect(WeatherKitProvider.bucket(.wintryMix) == .snowy)
        #expect(WeatherKitProvider.bucket(.clear) == .clear)
        #expect(WeatherKitProvider.bucket(.cloudy) == .clear)
        #expect(WeatherKitProvider.bucket(.windy) == .clear)
    }

    @Test func classifyIgnoresUnmappablePlaces() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let unmapped = mapItem(category: .police, latitude: 0.0001, longitude: 0.0001) // nearest, but unmapped
        let beach = mapItem(category: .beach, metersEast: 200)

        let result = ContextClassifier.classify(places: [unmapped, beach], userLocation: user)
        #expect(result == .beach)
    }

    private func mapItem(category: MKPointOfInterestCategory, latitude: Double, longitude: Double, name: String? = nil) -> MKMapItem {
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        let item = MKMapItem(placemark: placemark)
        item.pointOfInterestCategory = category
        if let name { item.name = name }
        return item
    }

    private func mapItem(category: MKPointOfInterestCategory, metersEast: Double, name: String? = nil) -> MKMapItem {
        mapItem(category: category, latitude: 0, longitude: metersEast / 111_320, name: name)
    }
}

// Stands in for LocationHandler: no CLLocationManager, no authorization prompt,
// no MKLocalSearch. The detector only ever asks for these two things.
private final class StubPOIProvider: POIProviding {
    var currentLocation: CLLocation?
    // the detector installs its evaluation hook here in start(); a real handler
    // would call it from didUpdateLocations
    var onLocationUpdate: ((CLLocation) -> Void)?
    // what the next search hands back -- nothing here touches MapKit
    var searchResult: Result<[MKMapItem], Error> = .success([])

    // how many searches the detector actually spent, and how wide the last one
    // reached. LR-21 gates the first and halves the second, and neither is
    // visible from the detector's observable state -- the whole point of the
    // gate is that a skipped search looks identical from the outside.
    private(set) var searchCount = 0
    private(set) var lastRequestedRadius: CLLocationDistance?

    func getPointsOfInterest(radius: CLLocationDistance,
                             filter: [MKPointOfInterestCategory]?,
                             completion: @escaping (Result<[MKMapItem], Error>) -> Void) {
        searchCount += 1
        lastRequestedRadius = radius
        completion(searchResult)
    }
}

// Stands in for whatever MKLocalSearch would have failed with.
private struct StubSearchError: Error {}

// Stands in for UserDefaults: a dictionary, no app domain, no plist, nothing
// left on disk for the next test to trip over. LR-13 writes on every state
// transition, so without this every detector in this file would be scribbling
// into the developer's own defaults -- and reading each other's leftovers back
// in on start().
private final class StubStateStore: KeyValueStoring {
    private var values: [String: Any] = [:]

    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func double(forKey defaultName: String) -> Double { values[defaultName] as? Double ?? 0 }
    // nil removes, the same way UserDefaults treats it
    func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            values[defaultName] = value
        } else {
            values[defaultName] = nil
        }
    }

    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

// A blob in the shape a pre-LR-15 build wrote: MusicContext *display* names,
// and no version field at all. Transcribed rather than reached for, because
// ContextDetector.PersistedState is private and — more to the point — because
// this is a description of what old builds put on disk, and that has stopped
// moving. Rebuilding it from the current struct would make the test agree with
// whatever the code does next, which is the opposite of what it's for.
private struct LegacyPersistedState: Codable {
    let confirmedContext: String
    let debts: [String: Double]
    let bufferedContext: String?
    let bufferExpiry: Date?
    let savedAt: Date
}

// The test clock, lifted out of makeDetector so more than one detector can read
// it. A relaunch is two detectors either side of some elapsed time, and time
// passing *between* them is the entire thing under test -- an `advance` closure
// that only reached the detector that returned it couldn't express that.
private final class StubClock {
    var current = Date(timeIntervalSince1970: 0)
    func advance(_ interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}

struct ContextDetectorTests {

    // The detector's reference is weak, so whatever we pass has to be owned
    // somewhere. Swift Testing builds a fresh suite value per test, so this
    // outlives the detector it's handed to — the old inline `LocationHandler()`
    // argument was deallocated before the first #expect ever ran.
    private let poiProvider = StubPOIProvider()

    // Fresh per test, like the provider above. Every detector a single test
    // builds shares both, so two of them stand in for one device either side of
    // a relaunch: same wall clock, same disk. Tests that build only one are
    // unaffected -- their `advance` still moves the only clock there is.
    private let clock = StubClock()
    private let store = StubStateStore()

    private func makeDetector(initial: MusicContext = .all) -> (ContextDetector, (TimeInterval) -> Void) {
        let detector = ContextDetector(
            poiProvider: poiProvider,
            initialContext: initial,
            minimumSearchDisplacement: 50, // the gating tests below are written against this
            dwellDuration: 30,
            debtAccumulationDuration: 480, // pinned rather than read from the store, so the arithmetic below is fixed
            switchBufferDuration: 180,
            store: store,
            weatherProvider: nil
        )
        // bound to a local so the closures capture the clock rather than the
        // suite value that happens to be holding it
        let clock = self.clock
        detector.now = { clock.current }
        let advance: (TimeInterval) -> Void = { clock.advance($0) }
        return (detector, advance)
    }

    private func location(metersEast: Double) -> CLLocation {
        CLLocation(latitude: 0, longitude: metersEast / 111_320)
    }

    // The detector applies search results on the main queue, so let those
    // blocks drain before asserting on anything they wrote. The main queue is
    // serial and FIFO, so anything enqueued ahead of this hop has already run
    // by the time it resumes -- deterministic, unlike a sleep.
    private func settle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: Lifecycle
    //
    // These cover the wiring that replaced the poll timer. They can't prove
    // anything about background behaviour -- that needs a locked device -- but
    // they do pin down that "running" means "subscribed to location delivery",
    // which is the part that used to be a Timer.

    @Test func startSubscribesToLocationDeliveryAndStopUnsubscribes() {
        let (detector, _) = makeDetector()
        #expect(poiProvider.onLocationUpdate == nil)

        detector.start()
        #expect(poiProvider.onLocationUpdate != nil)

        detector.stop()
        #expect(poiProvider.onLocationUpdate == nil)
    }

    @Test func stopBeforeStartIsHarmless() {
        let (detector, _) = makeDetector()
        detector.stop()
        #expect(poiProvider.onLocationUpdate == nil)

        // and a start still takes effect afterwards
        detector.start()
        #expect(poiProvider.onLocationUpdate != nil)
    }

    @Test func repeatedStartsKeepASingleSubscription() {
        let (detector, _) = makeDetector()
        detector.start()
        detector.start()
        // one stop is enough to leave nothing behind -- the second start was a
        // no-op rather than a second subscription
        detector.stop()
        #expect(poiProvider.onLocationUpdate == nil)
    }

    // MARK: Search gating
    //
    // Searches are gated on time (LR-12) and on displacement (LR-21). These
    // pin down the second: a user who hasn't moved re-scores the places
    // already in hand instead of buying the same answer again. Every fix is
    // advanced past the 10s rate limit first, so the time gate can never be
    // what's doing the work here.

    // Note each of these ends on detector.stop(). That's not just tidiness --
    // the provider's hook holds the detector weakly, so a detector whose last
    // use was start() could be released halfway through the test and quietly
    // take the subscription with it.

    @Test @MainActor func stationaryUserTriggersNoRepeatSearches() async {
        let (detector, advance) = makeDetector()
        poiProvider.currentLocation = location(metersEast: 0)

        detector.start() // start() evaluates once rather than sitting blind
        await settle()
        #expect(poiProvider.searchCount == 1)

        for _ in 0..<4 {
            advance(15)
            poiProvider.onLocationUpdate?(poiProvider.currentLocation!)
            await settle()
        }

        #expect(poiProvider.searchCount == 1)

        // ...and the pass itself kept running on the cached places. This is the
        // half that matters: the dwell window only closes on an evaluation, so
        // gating the search must never gate the pass. Empty results mean a
        // .traveling candidate at t0, promoted 30s later without a second
        // search ever being spent.
        #expect(detector.confirmedContext == .traveling)

        detector.stop()
    }

    @Test @MainActor func movingBeyondTheThresholdEarnsAFreshSearch() async {
        let (detector, advance) = makeDetector()
        poiProvider.currentLocation = location(metersEast: 0)

        detector.start()
        await settle()
        #expect(poiProvider.searchCount == 1)

        // a shuffle across the room stays inside the gate
        advance(15)
        poiProvider.currentLocation = location(metersEast: 30)
        poiProvider.onLocationUpdate?(poiProvider.currentLocation!)
        await settle()
        #expect(poiProvider.searchCount == 1)

        // a walk down the block clears it
        advance(15)
        poiProvider.currentLocation = location(metersEast: 120)
        poiProvider.onLocationUpdate?(poiProvider.currentLocation!)
        await settle()
        #expect(poiProvider.searchCount == 2)

        detector.stop()
    }

    // A failed search leaves nothing to re-score, so it must not arm the gate:
    // otherwise one flaky response would strand a stationary user with no data
    // until they got up and walked 50m.
    @Test @MainActor func failedSearchDoesNotArmTheDisplacementGate() async {
        let (detector, advance) = makeDetector()
        poiProvider.currentLocation = location(metersEast: 0)
        poiProvider.searchResult = .failure(StubSearchError())

        detector.start()
        await settle()
        #expect(poiProvider.searchCount == 1)

        advance(15)
        poiProvider.onLocationUpdate?(poiProvider.currentLocation!) // same spot
        await settle()
        #expect(poiProvider.searchCount == 2)

        detector.stop()
    }

    // The classifier owns the radius; this is the detector honouring it rather
    // than padding it on the way out.
    @Test @MainActor func detectorAsksForTheClassifierRadius() async {
        let (detector, _) = makeDetector()
        poiProvider.currentLocation = location(metersEast: 0)

        detector.start()
        await settle()

        #expect(poiProvider.lastRequestedRadius == ContextClassifier.searchRadius)

        detector.stop()
    }

    // MARK: Dwell

    @Test func sameContextObservationDoesNotSwitch() {
        let (detector, advance) = makeDetector(initial: .beach)
        detector.process(observation: .beach)
        advance(60)
        detector.process(observation: .beach)
        #expect(detector.confirmedContext == .beach)
        #expect(detector.candidateContext == nil)
    }

    @Test func noSwitchBeforeDwellWindowElapses() {
        let (detector, advance) = makeDetector(initial: .all)
        detector.process(observation: .beach) // candidate starts
        advance(10)
        detector.process(observation: .beach) // only 10s elapsed
        #expect(detector.confirmedContext == .all)
        #expect(detector.candidateContext == .beach)
    }

    @Test func switchesAfterDwellWindow() {
        let (detector, advance) = makeDetector(initial: .all)

        detector.process(observation: .store)
        advance(30)
        detector.process(observation: .store)

        // confirmedContext is the whole signal now — LR-08 removed the
        // onContextChange callback this used to also assert on, because the
        // observable property already says everything the callback did.
        #expect(detector.confirmedContext == .store)
        #expect(detector.candidateContext == nil)
    }

    @Test func revertingObservationResetsCandidate() {
        let (detector, advance) = makeDetector(initial: .all)
        detector.process(observation: .beach)
        advance(20)
        detector.process(observation: .all) // back to confirmed context — candidate dropped
        #expect(detector.candidateContext == nil)

        advance(20)
        detector.process(observation: .beach) // dwell clock restarts from zero
        #expect(detector.confirmedContext == .all)
        #expect(detector.candidateContext == .beach)
    }

    @Test func differentCandidateRestartsDwellClock() {
        let (detector, advance) = makeDetector(initial: .all)
        detector.process(observation: .beach)
        advance(25)
        detector.process(observation: .store) // new candidate — clock restarts
        advance(10)
        detector.process(observation: .store) // only 10s on the new candidate
        #expect(detector.confirmedContext == .all)
        advance(20)
        detector.process(observation: .store) // 30s elapsed on .store
        #expect(detector.confirmedContext == .store)
    }

    @Test func nilObservationPromotesToTraveling() {
        let (detector, advance) = makeDetector(initial: .beach)

        detector.process(observation: nil)
        advance(30)
        detector.process(observation: nil)

        #expect(detector.confirmedContext == .traveling)
    }

    // MARK: Debt

    @Test func debtAccruesOnlyForConfirmedContextWhileMoving() {
        let (detector, advance) = makeDetector(initial: .restaurant)
        detector.tickDebt(isMoving: true) // primes the tick clock
        advance(96)
        detector.tickDebt(isMoving: true) // 96s moving: 0.5 * 96/480 = 0.1
        #expect(abs(detector.debt(for: .restaurant) - 0.1) < 0.0001)
        #expect(detector.debt(for: .store) == 0)
    }

    @Test func debtDoesNotAccrueWhileStationary() {
        let (detector, advance) = makeDetector(initial: .restaurant)
        detector.tickDebt(isMoving: false)
        advance(600)
        detector.tickDebt(isMoving: false) // 10 minutes parked at the library
        #expect(detector.debt(for: .restaurant) == 0)
    }

    @Test func debtDecaysWhileStationary() {
        let (detector, advance) = makeDetector(initial: .restaurant)
        detector.tickDebt(isMoving: true)
        advance(192)
        detector.tickDebt(isMoving: true) // builds 0.2
        advance(96)
        detector.tickDebt(isMoving: false) // decays 0.1
        #expect(abs(detector.debt(for: .restaurant) - 0.1) < 0.0001)
    }

    @Test func debtIsCappedAtMax() {
        let (detector, advance) = makeDetector(initial: .restaurant)
        detector.tickDebt(isMoving: true)
        advance(48_000) // way past full accumulation
        detector.tickDebt(isMoving: true)
        #expect(detector.debt(for: .restaurant) == ContextClassifier.maxDebt)
    }

    @Test func debtAccumulationDurationReadsUserDefault() {
        let key = ContextDetector.debtAccumulationDefaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set(120.0, forKey: key) // spec's field-testing value
        let detector = ContextDetector(poiProvider: poiProvider, weatherProvider: nil)
        #expect(detector.debtAccumulationDuration == 120)

        UserDefaults.standard.removeObject(forKey: key)
        let fallback = ContextDetector(poiProvider: poiProvider, weatherProvider: nil)
        #expect(fallback.debtAccumulationDuration == ContextDetector.defaultDebtAccumulationDuration)
    }

    // MARK: Buffer zone

    @Test func debtDrivenSwitchArmsBufferAgainstFlapping() {
        let (detector, advance) = makeDetector(initial: .restaurant)
        // Debt-driven: without debt the restaurant would still be winning
        detector.process(observation: .store, observationIgnoringDebt: .restaurant)
        advance(30)
        detector.process(observation: .store, observationIgnoringDebt: .restaurant)
        #expect(detector.confirmedContext == .store)
        #expect(detector.bufferedContext == .restaurant)

        // The departed context reappears immediately — buffered, no candidacy
        detector.process(observation: .restaurant, observationIgnoringDebt: .restaurant)
        #expect(detector.candidateContext == nil)
        advance(30)
        detector.process(observation: .restaurant, observationIgnoringDebt: .restaurant)
        #expect(detector.confirmedContext == .store)

        // Once the 180s buffer expires it can compete (and win) again
        advance(150)
        detector.process(observation: .restaurant, observationIgnoringDebt: .restaurant)
        #expect(detector.candidateContext == .restaurant)
        advance(30)
        detector.process(observation: .restaurant, observationIgnoringDebt: .restaurant)
        #expect(detector.confirmedContext == .restaurant)
    }

    @Test func naturalSwitchDoesNotArmBuffer() {
        let (detector, advance) = makeDetector(initial: .restaurant)
        detector.process(observation: .park, observationIgnoringDebt: .park)
        advance(30)
        detector.process(observation: .park, observationIgnoringDebt: .park)
        #expect(detector.confirmedContext == .park)
        #expect(detector.bufferedContext == nil)
    }

    @Test func bufferReleasesEarlyOnceDebtDrains() {
        let (detector, advance) = makeDetector(initial: .restaurant)
        // Build a small debt balance while traveling
        detector.tickDebt(isMoving: true)
        advance(48)
        detector.tickDebt(isMoving: true) // 0.05 debt
        // Debt-driven switch away from the restaurant
        detector.process(observation: .store, observationIgnoringDebt: .restaurant)
        advance(30)
        detector.process(observation: .store, observationIgnoringDebt: .restaurant)
        #expect(detector.bufferedContext == .restaurant)

        // Debt fully drains well before the 180s buffer window is up
        advance(48)
        detector.tickDebt(isMoving: false)
        #expect(detector.debt(for: .restaurant) == 0)
        #expect(detector.bufferedContext == nil)
    }

    // MARK: Persistence
    //
    // A relaunch here is two detectors over one store and one clock: the first
    // is the process that got killed, the second is the one that comes back.
    // Most of these give the provider no location at all, so start() rehydrates
    // and then returns without evaluating -- which keeps them synchronous and
    // keeps the restore the only thing being measured.

    @Test func firstLaunchWithNothingSavedKeepsTheInitialContext() {
        let (detector, _) = makeDetector(initial: .all)
        detector.start()

        #expect(detector.confirmedContext == .all)
        #expect(detector.debts.isEmpty)
        #expect(detector.bufferedContext == nil)

        detector.stop()
    }

    @Test func relaunchRestoresTheConfirmedContext() {
        let (first, advance) = makeDetector(initial: .all)
        first.process(observation: .store)
        advance(30)
        first.process(observation: .store)
        #expect(first.confirmedContext == .store)

        // killed, and back four minutes later
        advance(240)
        let (second, _) = makeDetector(initial: .all)
        second.start()

        // .store rather than the .all it was constructed with -- which is the
        // whole point, and also why ContentView has to ask after start() rather
        // than before it
        #expect(second.confirmedContext == .store)

        second.stop()
    }

    @Test func relaunchRestoresDebtDecayedByTheTimeWeWereGone() {
        let (first, advance) = makeDetector(initial: .restaurant)
        first.tickDebt(isMoving: true) // primes the tick clock
        advance(192)
        first.tickDebt(isMoving: true) // 0.5 * 192/480 = 0.2 owed

        // gone for 96s, which is worth 0.1 of decay at the same rate
        advance(96)
        let (second, _) = makeDetector(initial: .all)
        second.start()

        #expect(abs(second.debt(for: .restaurant) - 0.1) < 0.0001)
        // and the ledger came back attached to the right context
        #expect(second.confirmedContext == .restaurant)

        second.stop()
    }

    // Unobserved time can pay debt down but never build it: nobody watched the
    // user walk anywhere while the process wasn't running.
    @Test func timeAwayDrainsDebtRatherThanAccruingIt() {
        let (first, advance) = makeDetector(initial: .restaurant)
        first.tickDebt(isMoving: true)
        advance(4_800)
        first.tickDebt(isMoving: true) // pinned at maxDebt
        #expect(first.debt(for: .restaurant) == ContextClassifier.maxDebt)

        // an hour away is far more than the 8-minute window takes to drain
        advance(3_600)
        let (second, _) = makeDetector(initial: .all)
        second.start()

        #expect(second.debt(for: .restaurant) == 0)
        // still inside the staleness cutoff, so the context outlives the debt
        // it used to carry
        #expect(second.confirmedContext == .restaurant)

        second.stop()
    }

    // MARK: Staleness

    @Test func stateOlderThanTheCutoffIsDiscardedRatherThanRestored() {
        let (first, advance) = makeDetector(initial: .all)
        first.process(observation: .beach)
        advance(30)
        first.process(observation: .beach)
        #expect(first.confirmedContext == .beach)

        // a night's sleep and then some. Past the cutoff this stops being
        // evidence about where anybody is now
        advance(ContextDetector.defaultMaximumRestoreAge + 1)
        let (second, _) = makeDetector(initial: .all)
        second.start()

        #expect(second.confirmedContext == .all) // the launch default, not .beach
        #expect(second.debts.isEmpty)
        // and it's cleared rather than merely ignored -- a third launch
        // shouldn't have to make the same judgement over again
        #expect(store.data(forKey: ContextDetector.stateDefaultsKey) == nil)

        second.stop()
    }

    // LR-15 respelt every context on disk, so a blob written by the build
    // before it says "Beaches" where this one says "beach". Left to decode, all
    // of it would parse and none of it would map: the confirmed context
    // reverting to the launch default and the ledger coming back empty, while
    // savedAt and bufferExpiry sailed through looking authoritative. The version
    // field is what makes that visible, and the answer is to throw the whole
    // blob away rather than restore the half of it that still parses.
    @Test func stateFromBeforeTheContextKeySplitIsDiscardedWholesale() throws {
        let legacy = LegacyPersistedState(
            confirmedContext: "Beaches",      // .beach, in the old spelling
            debts: ["Restaurants": 0.3],
            bufferedContext: nil,
            bufferExpiry: nil,
            savedAt: clock.current            // fresh, so staleness isn't what rejects it
        )
        store.set(try JSONEncoder().encode(legacy), forKey: ContextDetector.stateDefaultsKey)

        let (detector, _) = makeDetector(initial: .all)
        detector.start()

        #expect(detector.confirmedContext == .all) // the launch default, not .beach
        #expect(detector.debts.isEmpty)
        // and cleared, so a build that will never accept it doesn't re-read and
        // re-reject it on every launch
        #expect(store.data(forKey: ContextDetector.stateDefaultsKey) == nil)

        detector.stop()
    }

    @Test func stateExactlyAtTheCutoffStillRestores() {
        let (first, advance) = makeDetector(initial: .all)
        first.process(observation: .beach)
        advance(30)
        first.process(observation: .beach) // last write lands here

        advance(ContextDetector.defaultMaximumRestoreAge) // to the second
        let (second, _) = makeDetector(initial: .all)
        second.start()

        #expect(second.confirmedContext == .beach)

        second.stop()
    }

    // MARK: What deliberately doesn't survive

    @Test func dwellCandidateDoesNotSurviveARelaunch() {
        let (first, advance) = makeDetector(initial: .all)
        first.process(observation: .beach) // candidate opens
        advance(29)                        // one second short of promotion
        first.process(observation: .beach)
        #expect(first.candidateContext == .beach)

        // killed here, back an hour later and possibly a city away
        advance(3_600)
        let (second, _) = makeDetector(initial: .all)
        second.start()
        #expect(second.candidateContext == nil)
        #expect(second.candidateSince == nil)

        // ...so the first thing it sees has to serve the whole window again
        // rather than cashing in 29 seconds nobody watched
        second.process(observation: .beach)
        advance(29)
        second.process(observation: .beach)
        #expect(second.confirmedContext == .all)
        advance(1)
        second.process(observation: .beach)
        #expect(second.confirmedContext == .beach)

        second.stop()
    }

    // LR-21's search cache is in-memory only, so the first evaluation of a new
    // process always pays for a fresh look instead of answering from results
    // that were current in a process that no longer exists.
    @Test @MainActor func relaunchAlwaysSearchesRatherThanReusingTheCache() async {
        poiProvider.currentLocation = location(metersEast: 0)

        let (first, advance) = makeDetector(initial: .all)
        first.start()
        await settle()
        #expect(poiProvider.searchCount == 1)
        first.stop()

        // the same spot, well inside the 50m displacement gate: an in-process
        // fix here would have been re-scored from the cache for free
        advance(30)
        let (second, _) = makeDetector(initial: .all)
        second.start()
        await settle()
        #expect(poiProvider.searchCount == 2)

        second.stop()
    }

    // MARK: Buffer

    @Test func switchBufferSurvivesARelaunchInsideItsWindow() {
        let (first, advance) = makeDetector(initial: .restaurant)
        // A debt-driven switch always has debt behind it -- that's what made it
        // debt-driven -- and the buffer is released early once that drains, so
        // a restore has to carry both or neither.
        first.tickDebt(isMoving: true)
        advance(192)
        first.tickDebt(isMoving: true) // 0.2 owed on the restaurant
        first.process(observation: .store, observationIgnoringDebt: .restaurant)
        advance(30)
        first.process(observation: .store, observationIgnoringDebt: .restaurant)
        #expect(first.bufferedContext == .restaurant)

        // jetsammed 30s into a 180s sentence
        advance(30)
        let (second, _) = makeDetector(initial: .all)
        second.start()
        #expect(second.bufferedContext == .restaurant)
        #expect(second.debt(for: .restaurant) > 0)

        // which is what it's for: start() evaluates immediately, sees the
        // context we just left, and must not flap straight back into it
        second.process(observation: .restaurant, observationIgnoringDebt: .restaurant)
        advance(30)
        second.process(observation: .restaurant, observationIgnoringDebt: .restaurant)
        #expect(second.confirmedContext == .store)

        second.stop()
    }

    @Test func expiredSwitchBufferIsNotRestored() {
        let (first, advance) = makeDetector(initial: .restaurant)
        first.tickDebt(isMoving: true)
        advance(4_800)
        first.tickDebt(isMoving: true) // maxDebt, so it can't drain inside the gap below
        first.process(observation: .store, observationIgnoringDebt: .restaurant)
        advance(30)
        first.process(observation: .store, observationIgnoringDebt: .restaurant)
        #expect(first.bufferedContext == .restaurant)

        // back after the 180s window has run out: no sentence left to serve
        advance(300)
        let (second, _) = makeDetector(initial: .all)
        second.start()

        #expect(second.bufferedContext == nil)
        #expect(second.debt(for: .restaurant) > 0) // the debt behind it does survive
        #expect(second.confirmedContext == .store)

        second.stop()
    }
}
