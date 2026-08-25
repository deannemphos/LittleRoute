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

    // MARK: External factors

    @Test func rainOverridesPOIsAndSpeed() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let beach = mapItem(category: .beach, metersEast: 50)
        let factors = ContextClassifier.Factors(weather: .rainy, speed: 30) // raining AND highway speed

        let evaluation = ContextClassifier.evaluate(places: [beach], userLocation: user, factors: factors)

        #expect(evaluation.context == .rainy)
        #expect(evaluation.contextIgnoringDebt == .rainy)
        #expect(!evaluation.zones.isEmpty) // the map still gets its zones
    }

    @Test func snowOverridesPOIsAndSpeed() {
        let factors = ContextClassifier.Factors(weather: .snowy, speed: 30)
        #expect(ContextClassifier.contextOverride(for: factors) == .snowy)
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
    // observable from the detector's published state -- the whole point of the
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

struct ContextDetectorTests {

    // The detector's reference is weak, so whatever we pass has to be owned
    // somewhere. Swift Testing builds a fresh suite value per test, so this
    // outlives the detector it's handed to — the old inline `LocationHandler()`
    // argument was deallocated before the first #expect ever ran.
    private let poiProvider = StubPOIProvider()

    private func makeDetector(initial: MusicContext = .all) -> (ContextDetector, (TimeInterval) -> Void) {
        let detector = ContextDetector(
            poiProvider: poiProvider,
            initialContext: initial,
            minimumSearchDisplacement: 50, // the gating tests below are written against this
            dwellDuration: 30,
            debtAccumulationDuration: 480, // pin explicitly so UserDefaults can't leak into tests
            switchBufferDuration: 180,
            weatherProvider: nil
        )
        var currentTime = Date(timeIntervalSince1970: 0)
        detector.now = { currentTime }
        let advance: (TimeInterval) -> Void = { currentTime = currentTime.addingTimeInterval($0) }
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
        var fired: MusicContext?
        detector.onContextChange = { fired = $0 }

        detector.process(observation: .store)
        advance(30)
        detector.process(observation: .store)

        #expect(detector.confirmedContext == .store)
        #expect(fired == .store)
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
        var fired: MusicContext?
        detector.onContextChange = { fired = $0 }

        detector.process(observation: nil)
        advance(30)
        detector.process(observation: nil)

        #expect(detector.confirmedContext == .traveling)
        #expect(fired == .traveling)
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
}
