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
            var songs = try orderedSongs(in: modelContext)
            if songs.isEmpty { songs = audio.loadSongsFromBundle(modelContext: modelContext) }
            audio.currentContext = detector.confirmedContext
            audio.reloadQueue(newContext: detector.confirmedContext, shuffle: audio.isShuffled, songs: songs)
            audio.startPlaybackIfNothingElseIsPlaying()
        } catch {
            audio.reportPlaybackError("Your music library could not be read. Please reopen LittleRoute to retry.")
            Log.library.error("Playback bootstrap could not read the library")
        }
    }

    private func apply(_ context: MusicContext) {
        guard !storeHealth.isDegraded else { return }
        do {
            let songs = try orderedSongs(in: ModelContext(modelContext.container))
            audio.switchContext(to: context, songs: songs)
        } catch {
            audio.reportPlaybackError("The new context's music could not be loaded. Keeping the current music.")
            Log.library.error("Context transition could not read the library")
        }

    }

    private func orderedSongs(in context: ModelContext) throws -> [Song] {
        try context.fetch(FetchDescriptor<Song>()).sorted {
            if $0.title == $1.title { return $0.songName < $1.songName }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
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
