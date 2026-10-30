import Testing
import Foundation
import CoreLocation
import MapKit
@testable import LittleRoute

@MainActor
final class DetectorFlowTests {
    private final class Provider: POIProviding {
        var currentLocation: CLLocation?
        var onLocationUpdate: ((CLLocation) -> Void)?
        var requests: [(@MainActor (Result<[MKMapItem], Error>) -> Void)] = []
        func getPointsOfInterest(radius: CLLocationDistance, filter: [MKPointOfInterestCategory]?,
                                 completion: @escaping @MainActor (Result<[MKMapItem], Error>) -> Void) {
            requests.append(completion)
        }
    }

    private final class Store: KeyValueStoring {
        var values: [String: Any] = [:]
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    }

    private let provider = Provider()
    private let store = Store()
    private var clock = Date(timeIntervalSince1970: 1_000)

    private func detector() -> ContextDetector {
        let detector = ContextDetector(poiProvider: provider, store: store, weatherProvider: nil)
        detector.now = { self.clock }
        return detector
    }

    private func deliver(_ seconds: Double, accuracy: Double = 10, age: Double = 0, speed: Double = 0) {
        clock = Date(timeIntervalSince1970: 1_000 + seconds)
        let location = CLLocation(coordinate: .init(latitude: 0, longitude: 0), altitude: 0,
                                  horizontalAccuracy: accuracy, verticalAccuracy: 10,
                                  course: 0, speed: speed, timestamp: clock.addingTimeInterval(-age))
        provider.currentLocation = location
        provider.onLocationUpdate?(location)
    }

    @Test func cachedFixesFinishDwellWithoutBuyingAnotherSearch() async {
        let detector = detector()
        deliver(0)
        detector.start()
        provider.requests[0](.success([]))
        await detector.waitForPendingGeometry()
        for time in stride(from: 5.0, through: 25.0, by: 5) { deliver(time) }
        #expect(detector.confirmedContext == .all)
        deliver(30)
        #expect(detector.confirmedContext == .traveling)
        #expect(provider.requests.count == 1)
        #expect(detector.debts.isEmpty)
        #expect(!detector.varietyEnabled)
        detector.stop()
    }

    @Test func invalidFixesCannotSpendSearchBudgetOrAdvanceDwell() {
        let detector = detector()
        deliver(0, accuracy: -1)
        detector.start()
        deliver(5, accuracy: 100)
        deliver(10, age: 30)
        #expect(provider.requests.isEmpty)
        #expect(detector.confirmedContext == .all)
        #expect(detector.candidateContext == nil)
        detector.stop()
    }

    @Test func repeatedRefreshesCoalesceAndDoNotForcePlayback() async {
        let detector = detector()
        deliver(0)
        detector.start()
        for _ in 0..<20 { detector.refreshNow() }
        #expect(provider.requests.count == 1)
        provider.requests[0](.success([]))
        await detector.waitForPendingGeometry()
        #expect(detector.confirmedContext == .all)
        #expect(detector.canSwitchNow)
        detector.switchNow()
        #expect(detector.confirmedContext == .traveling)
        #expect(provider.requests.count == 1)
        detector.stop()
    }

    @Test func cancelledRequestCannotPublishAfterRestart() async {
        let detector = detector()
        deliver(0)
        detector.start()
        let obsolete = provider.requests[0]
        detector.stop()
        deliver(20)
        detector.start()
        #expect(provider.requests.count == 2)
        obsolete(.success([]))
        await detector.waitForPendingGeometry()
        #expect(detector.snapshot == nil)
        #expect(detector.isSearching)
        provider.requests[1](.success([]))
        await detector.waitForPendingGeometry()
        #expect(detector.snapshot != nil)
        #expect(!detector.isSearching)
        detector.stop()
    }

    @Test func speedTransitionStillNeedsFreshDwellEvidence() {
        let detector = detector()
        deliver(0, speed: 20)
        detector.start()
        for time in stride(from: 5.0, through: 25.0, by: 5) { deliver(time, speed: 20) }
        #expect(detector.confirmedContext == .all)
        deliver(30, speed: 20)
        #expect(detector.confirmedContext == .traveling)
        #expect(detector.musicReason == "High-speed travel")
        #expect(provider.requests.count == 1)
        detector.stop()
    }
}
