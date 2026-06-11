//
//  ContextDetectionTests.swift
//  LittleRouteTests
//

import Testing
import MapKit
import CoreLocation
@testable import LittleRoute

struct ContextClassifierTests {

    @Test func mapsKnownCategoriesToContexts() {
        #expect(ContextClassifier.context(for: .beach) == .beach)
        #expect(ContextClassifier.context(for: .shoppingCenter) == .store)
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

    @Test func classifyPicksNearestMappablePlace() {
        let user = CLLocation(latitude: 0, longitude: 0)
        // beach is farther than the shopping center
        let far = mapItem(category: .beach, latitude: 0.01, longitude: 0.01)
        let near = mapItem(category: .shoppingCenter, latitude: 0.001, longitude: 0.001)

        let result = ContextClassifier.classify(places: [far, near], userLocation: user)
        #expect(result == .store)
    }

    @Test func classifyIgnoresUnmappablePlaces() {
        let user = CLLocation(latitude: 0, longitude: 0)
        let unmapped = mapItem(category: .police, latitude: 0.0001, longitude: 0.0001) // nearest, but unmapped
        let beach = mapItem(category: .beach, latitude: 0.01, longitude: 0.01)

        let result = ContextClassifier.classify(places: [unmapped, beach], userLocation: user)
        #expect(result == .beach)
    }

    private func mapItem(category: MKPointOfInterestCategory, latitude: Double, longitude: Double) -> MKMapItem {
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        let item = MKMapItem(placemark: placemark)
        item.pointOfInterestCategory = category
        return item
    }
}

struct ContextDetectorTests {

    private func makeDetector(initial: AudioPlayerManager.Context = .all) -> (ContextDetector, (TimeInterval) -> Void) {
        let detector = ContextDetector(locationHandler: LocationHandler(), initialContext: initial, dwellDuration: 30)
        var currentTime = Date(timeIntervalSince1970: 0)
        detector.now = { currentTime }
        let advance: (TimeInterval) -> Void = { currentTime = currentTime.addingTimeInterval($0) }
        return (detector, advance)
    }

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
        var fired: AudioPlayerManager.Context?
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
        var fired: AudioPlayerManager.Context?
        detector.onContextChange = { fired = $0 }

        detector.process(observation: nil)
        advance(30)
        detector.process(observation: nil)

        #expect(detector.confirmedContext == .traveling)
        #expect(fired == .traveling)
    }
}
