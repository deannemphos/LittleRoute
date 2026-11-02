import Testing
import Foundation
import SwiftData
import CoreLocation
import MapKit
@testable import LittleRoute

@MainActor
struct PlaybackCoordinatorTests {
    private final class Store: KeyValueStoring {
        var values: [String: Any] = [:]
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    }

    private final class Provider: POIProviding {
        var currentLocation: CLLocation?
        var onLocationUpdate: ((CLLocation) -> Void)?
        func getPointsOfInterest(radius: CLLocationDistance, filter: [MKPointOfInterestCategory]?,
                                 completion: @escaping @MainActor (Result<[MKMapItem], Error>) -> Void) {
            completion(.success([]))
        }
    }

    @Test func confirmedContextReachesPlaybackWithoutAnyView() throws {
        let schema = Schema(versionedSchema: SongSchemaV5.self)
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let audio = AudioPlayerManager(managesSystemAudio: false)
        let provider = Provider()
        let detector = ContextDetector(poiProvider: provider, minimumResidenceDuration: 0, store: Store(), weatherProvider: nil)
        let coordinator = PlaybackCoordinator(detector: detector, audio: audio,
                                              modelContext: container.mainContext, storeHealth: .onDisk)
        coordinator.start()
        let editContext = ModelContext(container)
        editContext.insert(Song(title: "Newly Imported", songName: "fresh-song", artist: "Test",
                                locations: ["park"], populationMin: 0, populationMax: 1))
        try editContext.save()
        var clock = Date()
        detector.now = { clock }
        for _ in 0..<7 {
            detector.process(observation: .park)
            clock.addTimeInterval(5)
        }
        #expect(detector.confirmedContext == .park)
        #expect(audio.currentContext == .park)
        #expect(audio.isPaused)
        #expect(audio.songQueue.map(\.title) == ["Newly Imported"])
        detector.stop()
    }

    @Test func degradedStoreDoesNotSeedOrStartPlayback() throws {
        let schema = Schema(versionedSchema: SongSchemaV5.self)
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let provider = Provider()
        let detector = ContextDetector(poiProvider: provider, store: Store(), weatherProvider: nil)
        let audio = AudioPlayerManager(managesSystemAudio: false)
        let coordinator = PlaybackCoordinator(detector: detector, audio: audio,
                                              modelContext: container.mainContext, storeHealth: .inMemory(reason: "fixture"))
        coordinator.start()
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Song>()) == 0)
        #expect(audio.songQueue.isEmpty)
        #expect(audio.isPaused)
        detector.stop()
    }
}
