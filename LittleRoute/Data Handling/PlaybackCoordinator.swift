import Foundation
import SwiftData
import Observation
import os

@MainActor
@Observable
final class PlaybackCoordinator {
    @ObservationIgnored private let detector: ContextDetector
    @ObservationIgnored private let audio: AudioPlayerManager
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let storeHealth: ModelStoreHealth
    @ObservationIgnored private var started = false

    init(detector: ContextDetector, audio: AudioPlayerManager,
         modelContext: ModelContext, storeHealth: ModelStoreHealth) {
        self.detector = detector
        self.audio = audio
        self.modelContext = modelContext
        self.storeHealth = storeHealth
    }

    func start() {
        guard !started else { return }
        started = true
        detector.onContextChange = { [weak self] context in self?.apply(context) }
        detector.start()
        guard !storeHealth.isDegraded else { return }
        do {
            var songs = try modelContext.fetch(FetchDescriptor<Song>(sortBy: [SortDescriptor(\.title), SortDescriptor(\.songName)]))
            if songs.isEmpty { songs = audio.loadSongsFromBundle(modelContext: modelContext) }
            audio.currentContext = detector.confirmedContext
            audio.reloadQueue(newContext: detector.confirmedContext, shuffle: audio.isShuffled, songs: songs)
            audio.startPlaybackIfNothingElseIsPlaying()
        } catch {
            audio.playbackError = "Your music library could not be read. Please reopen LittleRoute to retry."
            Log.library.error("Playback bootstrap could not read the library")
        }
    }

    private func apply(_ context: MusicContext) {
        guard !storeHealth.isDegraded else { return }
        do {
            let songs = try modelContext.fetch(FetchDescriptor<Song>(sortBy: [SortDescriptor(\.title), SortDescriptor(\.songName)]))
            audio.switchContext(to: context, songs: songs)
        } catch {
            audio.playbackError = "The new context's music could not be loaded. Keeping the current music."
            Log.library.error("Context transition could not read the library")
        }
    }

    static var isTesting: Bool {
        #if DEBUG
        let process = ProcessInfo.processInfo
        return process.arguments.contains("--ui-testing") ||
            process.environment["XCTestConfigurationFilePath"] != nil ||
            process.environment["XCTestSessionIdentifier"] != nil
        #else
        return false
        #endif
    }
}
