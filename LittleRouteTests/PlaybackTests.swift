import Testing
import Foundation
import AVFoundation
import SwiftData
@testable import LittleRoute

enum PlaybackAudioFixture {
    static func wav(seconds: Int = 8, sample: Int16 = 0) -> Data {
        let samples = 8_000 * seconds
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + samples * 2)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(8_000)); number(UInt32(16_000))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(samples * 2))
        for _ in 0..<samples { number(sample) }
        return data
    }
}

private final class RejectingPlayPlayer: AVAudioPlayer {
    override func play() -> Bool { false }
}

private final class RejectingPreparePlayer: AVAudioPlayer {
    override func prepareToPlay() -> Bool { false }
}

@MainActor
@Suite(.serialized)
struct PlaybackTests {
    private func song(_ name: String, contexts: [MusicContext] = [.all]) -> Song {
        Song(title: name, songName: name, artist: "Test Artist",
             locations: contexts.map(\.storageKey), populationMin: 0, populationMax: 1_000_000)
    }

    private func songs(_ names: String..., contexts: [MusicContext] = [.all]) -> [Song] {
        names.map { song($0, contexts: contexts) }
    }

    private func manager(loading songs: [Song] = [], context: MusicContext = .all,
                         shuffle: Bool = false) -> AudioPlayerManager {
        let audio = PlaybackAudioFixture.wav()
        let manager = AudioPlayerManager(playerFactory: { _ in try AVAudioPlayer(data: audio) },
                                         managesSystemAudio: false)
        manager.reloadQueue(newContext: context, shuffle: shuffle, songs: songs)
        return manager
    }

    private func stop(_ manager: AudioPlayerManager) {
        manager.reloadQueue(newContext: .all, shuffle: false, songs: [])
    }

    @Test func exactContextExcludesAllFallbackAndKeepsCallerOrder() {
        let library = [song("all"), song("beach", contexts: [.beach]),
                       song("both", contexts: [.beach, .gym]), song("gym", contexts: [.gym])]
        let manager = manager(loading: library, context: .beach)
        defer { stop(manager) }
        #expect(manager.songQueue.map(\.songName) == ["beach", "both"])
        #expect(manager.queueSource == .beach)
        #expect(manager.currentContext == .beach)
    }

    @Test func noExactMatchesUsesOnlyAllTaggedSongs() {
        let library = [song("all-a"), song("gym", contexts: [.gym]), song("all-b")]
        let manager = manager(loading: library, context: .beach)
        defer { stop(manager) }
        #expect(manager.songQueue.map(\.songName) == ["all-a", "all-b"])
        #expect(manager.queueSource == .all)
        #expect(manager.currentContext == .beach)
        #expect(manager.currentSong?.songName == "all-a")
    }

    @Test func loadingPreparesARealPlayerWithoutAutoplay() {
        let manager = manager(loading: songs("d", "a", "c", "b"))
        defer { stop(manager) }
        #expect(manager.songQueue.map(\.songName) == ["d", "a", "c", "b"])
        #expect(manager.currentSong?.songName == "d")
        #expect(manager.songLength > 7)
        #expect(manager.currentTime == 0)
        #expect(manager.isPaused)
        #expect(manager.playbackError == nil)
    }

    @Test func reloadFollowsSurvivingSongAndPreservesPlayhead() {
        let a = song("a")
        let b = song("b")
        let c = song("c", contexts: [.all, .beach])
        let d = song("d", contexts: [.all, .beach])
        let e = song("e", contexts: [.all, .beach])
        let library = [a, b, c, d, e]
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.skip()
        manager.skip()
        manager.seek(to: 3)
        manager.reloadQueue(newContext: .beach, shuffle: false, songs: library)
        #expect(manager.songQueue.map(\.songName) == ["c", "d", "e"])
        #expect(manager.currentSong === c)
        #expect(manager.currentTime >= 3)
        #expect(!manager.isPaused)
        manager.skip()
        #expect(manager.currentSong === d)
    }

    @Test func reloadSelectsFirstWhenLoadedSongNoLongerMatches() {
        let library = [song("a"), song("b", contexts: [.all, .beach]),
                       song("c", contexts: [.all, .beach])]
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.reloadQueue(newContext: .beach, shuffle: false, songs: library)
        #expect(manager.currentSong?.songName == "b")
        #expect(manager.isPaused)
        manager.skip()
        #expect(manager.currentSong?.songName == "c")
    }

    @Test func explicitKeepCurrentFalseRestartsAtTop() {
        let library = songs("a", "b", "c", contexts: [.all, .beach])
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.skip()
        manager.reloadQueue(newContext: .beach, shuffle: false, songs: library, keepCurrentSong: false)
        #expect(manager.currentSong?.songName == "a")
        #expect(manager.currentTime == 0)
    }

    @Test func shuffleRoundTripsAndActuallyReorders() {
        let library = songs("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8")
        let manager = manager(loading: library)
        defer { stop(manager) }
        let ordered = library.map(\.songName)
        var differed = false
        for _ in 0..<10 {
            manager.toggleShuffle()
            #expect(manager.isShuffled)
            #expect(manager.songQueue.count == ordered.count)
            #expect(Set(manager.songQueue.map(\.songName)) == Set(ordered))
            differed = differed || manager.songQueue.map(\.songName) != ordered
            manager.toggleShuffle()
            #expect(!manager.isShuffled)
            #expect(manager.songQueue.map(\.songName) == ordered)
        }
        #expect(differed)
    }

    @Test func shuffleBothDirectionsFollowsLoadedSong() throws {
        let manager = manager(loading: songs("s1", "s2", "s3", "s4", "s5"))
        defer { stop(manager) }
        manager.skip()
        manager.skip()
        for _ in 0..<2 {
            let playing = try #require(manager.currentSong)
            manager.toggleShuffle()
            #expect(manager.currentSong === playing)
            let order = manager.songQueue.map(\.songName)
            let index = try #require(order.firstIndex(of: playing.songName))
            manager.skip()
            #expect(manager.currentSong?.songName == order[(index + 1) % order.count])
        }
    }

    @Test func reloadHonorsShuffleArgumentAndRetainsUnshuffledOrder() {
        let library = songs("s1", "s2", "s3", "s4")
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.reloadQueue(newContext: .all, shuffle: true, songs: library)
        #expect(manager.isShuffled)
        #expect(Set(manager.songQueue.map(\.songName)) == Set(library.map(\.songName)))
        manager.toggleShuffle()
        #expect(manager.songQueue.map(\.songName) == library.map(\.songName))
    }

    @Test func skipPreviousAndSelectionFollowQueueIndices() {
        let library = songs("a", "b", "c")
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.previous()
        #expect(manager.currentSong?.songName == "c")
        manager.skip()
        #expect(manager.currentSong?.songName == "a")
        manager.skip()
        manager.skip()
        manager.previous()
        #expect(manager.currentSong?.songName == "b")
        manager.play(song: library[2])
        #expect(manager.currentSong?.songName == "c")
        manager.skip()
        #expect(manager.currentSong?.songName == "a")
        manager.play(song: song("outsider", contexts: [.gym]))
        #expect(manager.currentSong?.songName == "a")
        manager.skip()
        #expect(manager.currentSong?.songName == "b")
    }

    @Test func singleSongWrapsBothWays() {
        let only = song("only")
        let manager = manager(loading: [only])
        defer { stop(manager) }
        manager.skip()
        #expect(manager.currentSong === only)
        manager.previous()
        #expect(manager.currentSong === only)
    }

    @Test func unmatchedExactAndFallbackPoolsClearAllPlayerState() {
        let library = songs("a", "b", contexts: [.beach])
        let manager = manager(loading: library, context: .beach)
        defer { stop(manager) }
        manager.skip()
        manager.reloadQueue(newContext: .gym, shuffle: false, songs: library)
        #expect(manager.songQueue.isEmpty)
        #expect(manager.currentSong == nil)
        #expect(manager.isPaused)
        #expect(manager.songLength == 0)
        #expect(manager.currentTime == 0)
        #expect(manager.progress == 0)
        #expect(manager.playbackError == nil)
        manager.reloadQueue(newContext: .beach, shuffle: false, songs: library)
        #expect(manager.currentSong?.songName == "a")
    }

    @Test func emptyLibraryAndTransportRemainEmpty() {
        let manager = manager(loading: songs("a", "b"))
        stop(manager)
        manager.skip()
        manager.previous()
        manager.musicPlayPause()
        manager.startPlaybackIfNothingElseIsPlaying()
        manager.seek(to: 4)
        #expect(manager.songQueue.isEmpty)
        #expect(manager.currentSong == nil)
        #expect(manager.isPaused)
        #expect(manager.currentTime == 0)
    }

    @Test func switchingContextWhilePausedDoesNotStartPlayback() {
        let library = [song("a"), song("b", contexts: [.beach]), song("c", contexts: [.beach])]
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.switchContext(to: .beach, songs: library)
        #expect(manager.currentContext == .beach)
        #expect(manager.currentSong?.songName == "b")
        #expect(manager.songQueue.map(\.songName) == ["b", "c"])
        #expect(manager.isPaused)
    }

    @Test func sameContextStillAcceptsTheLatestLibrary() async throws {
        let library = songs("a", "b", "c")
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.skip()
        manager.switchContext(to: .all, songs: [library[0]], fadeDuration: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.songQueue.map(\.songName) == ["a"])
        #expect(manager.currentSong?.songName == "a")
    }

    @Test func matchingTrackContinuesAcrossContextWithoutRecreatingPlayer() {
        let library = songs("a", "b", contexts: [.all, .beach])
        let audio = PlaybackAudioFixture.wav()
        var players: [AVAudioPlayer] = []
        let manager = AudioPlayerManager(playerFactory: { _ in
            let player = try AVAudioPlayer(data: audio)
            players.append(player)
            return player
        }, managesSystemAudio: false)
        defer { stop(manager) }
        manager.reloadQueue(newContext: .all, shuffle: false, songs: library)
        manager.musicPlayPause()
        manager.seek(to: 3)
        manager.switchContext(to: .beach, songs: library)
        #expect(players.count == 1)
        #expect(manager.currentSong === library[0])
        #expect(manager.currentTime >= 3)
        #expect(!manager.isPaused)
        #expect(manager.queueSource == .beach)
    }

    @Test func pauseCancelsFadeWithoutDelayedRestart() async throws {
        let library = [song("a"), song("b", contexts: [.beach])]
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.musicPlayPause()
        #expect(!manager.isPaused)
        manager.switchContext(to: .beach, songs: library, fadeDuration: 0.04)
        manager.musicPlayPause()
        let pausedSong = manager.currentSong
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.isPaused)
        #expect(manager.currentSong === pausedSong)
    }

    @Test func skipAndSelectionCancelPendingFade() async throws {
        let library = [song("a"), song("b", contexts: [.beach]), song("c", contexts: [.beach])]
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.musicPlayPause()
        manager.switchContext(to: .beach, songs: library, fadeDuration: 0.04)
        manager.skip()
        #expect(manager.currentSong?.songName == "b")
        manager.play(song: library[2])
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.currentSong?.songName == "c")
        #expect(!manager.isPaused)
    }

    @Test func newestContextWinsBothFadePhases() async throws {
        let library = [song("a"), song("b", contexts: [.beach]), song("c", contexts: [.gym])]
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.musicPlayPause()
        manager.switchContext(to: .beach, songs: library, fadeDuration: 0.04)
        manager.switchContext(to: .gym, songs: library, fadeDuration: 0.04)
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.currentSong?.songName == "c")
        #expect(manager.currentContext == .gym)
        #expect(manager.queueSource == .gym)
        #expect(!manager.isPaused)
    }

    @Test func seekingCancelsFadeAndKeepsCurrentPlayerAtRequestedTime() async throws {
        let library = [song("a"), song("b", contexts: [.beach])]
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.musicPlayPause()
        manager.switchContext(to: .beach, songs: library, fadeDuration: 0.04)
        manager.seek(to: 2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(manager.currentSong?.songName == "a")
        #expect(manager.currentTime >= 2)
        #expect(!manager.isPaused)
    }

    @Test func pauseDuringFadeInCannotRestartOrLeaveThePlayerMuted() async throws {
        let audio = PlaybackAudioFixture.wav()
        var players: [AVAudioPlayer] = []
        let library = [song("a"), song("b", contexts: [.beach])]
        let manager = AudioPlayerManager(playerFactory: { _ in
            let player = try AVAudioPlayer(data: audio)
            players.append(player)
            return player
        }, managesSystemAudio: false)
        defer { stop(manager) }
        manager.reloadQueue(newContext: .all, shuffle: false, songs: library)
        manager.musicPlayPause()
        manager.switchContext(to: .beach, songs: library, fadeDuration: 0.04)
        // Wait for the new player, not an assumed audio-device scheduling interval.
        for _ in 0..<100 where players.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(manager.currentSong?.songName == "b")
        manager.musicPlayPause()
        try await Task.sleep(for: .milliseconds(150))
        #expect(manager.isPaused)
        #expect(players.last?.volume == 1)
        #expect(manager.currentSong?.songName == "b")
    }

    @Test func failedLoadAfterFadeClearsStaleMetadata() async throws {
        let audio = PlaybackAudioFixture.wav()
        let library = [song("good"), song("missing", contexts: [.beach])]
        let manager = AudioPlayerManager(playerFactory: { song in
            if song.songName == "missing" { throw CocoaError(.fileReadNoSuchFile) }
            return try AVAudioPlayer(data: audio)
        }, managesSystemAudio: false)
        defer { stop(manager) }
        manager.reloadQueue(newContext: .all, shuffle: false, songs: library)
        manager.musicPlayPause()
        manager.switchContext(to: .beach, songs: library, fadeDuration: 0.04)
        try await Task.sleep(for: .milliseconds(150))
        #expect(manager.currentSong == nil)
        #expect(manager.isPaused)
        #expect(manager.songLength == 0)
        #expect(manager.playbackError?.contains("missing") == true)
    }

    @Test func reloadDuringFadeUsesFreshSongsRatherThanCapturedLibrary() async throws {
        let library = [song("a"), song("stale", contexts: [.beach])]
        let fresh = song("fresh", contexts: [.beach])
        let manager = manager(loading: library)
        defer { stop(manager) }
        manager.musicPlayPause()
        manager.switchContext(to: .beach, songs: library, fadeDuration: 0.04)
        manager.reloadQueue(newContext: .beach, shuffle: false, songs: [fresh])
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.currentSong === fresh)
        #expect(manager.songQueue.map(\.songName) == ["fresh"])
        #expect(!manager.isPaused)
        manager.switchContext(to: .gym, songs: [song("gym", contexts: [.gym])], fadeDuration: 0.04)
        stop(manager)
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.currentSong == nil)
        #expect(manager.isPaused)
    }

    @Test func failedLoadNeverPublishesNewTitleOverOldPlayer() {
        let audio = PlaybackAudioFixture.wav()
        let manager = AudioPlayerManager(playerFactory: { song in
            if song.songName == "missing" { throw CocoaError(.fileReadNoSuchFile) }
            return try AVAudioPlayer(data: audio)
        }, managesSystemAudio: false)
        defer { stop(manager) }
        manager.reloadQueue(newContext: .all, shuffle: false, songs: songs("good", "missing"))
        manager.musicPlayPause()
        manager.skip()
        #expect(manager.currentSong == nil)
        #expect(manager.isPaused)
        #expect(manager.currentTime == 0)
        #expect(manager.songLength == 0)
        #expect(manager.playbackError?.contains("missing") == true)
        manager.skip()
        #expect(manager.currentSong?.songName == "good")
        #expect(manager.playbackError == nil)
    }

    @Test func failedPrepareAndPlayAreTruthful() {
        let audio = PlaybackAudioFixture.wav()
        let prepareFailure = AudioPlayerManager(playerFactory: { _ in
            try RejectingPreparePlayer(data: audio)
        }, managesSystemAudio: false)
        defer { stop(prepareFailure) }
        prepareFailure.reloadQueue(newContext: .all, shuffle: false, songs: songs("bad"))
        #expect(prepareFailure.currentSong == nil)
        #expect(prepareFailure.songLength == 0)
        #expect(prepareFailure.isPaused)
        #expect(prepareFailure.playbackError != nil)
        let playFailure = AudioPlayerManager(playerFactory: { _ in
            try RejectingPlayPlayer(data: audio)
        }, managesSystemAudio: false)
        defer { stop(playFailure) }
        playFailure.reloadQueue(newContext: .all, shuffle: false, songs: songs("valid"))
        playFailure.musicPlayPause()
        #expect(playFailure.currentSong?.songName == "valid")
        #expect(playFailure.songLength > 0)
        #expect(playFailure.isPaused)
        #expect(playFailure.playbackError != nil)
    }

    @Test func seekClampsRejectsNonfiniteValuesAndDoesNotRebuildQueue() {
        let manager = manager(loading: songs("a", "b"))
        defer { stop(manager) }
        manager.seek(to: 3)
        #expect(abs(manager.currentTime - 3) < 0.01)
        #expect(abs(manager.progress - 3 / manager.songLength) < 0.01)
        manager.seek(to: .nan)
        manager.seek(to: .infinity)
        #expect(abs(manager.currentTime - 3) < 0.01)
        manager.seek(to: -10)
        #expect(manager.currentTime == 0)
        manager.seek(to: 100)
        #expect(manager.currentTime <= manager.songLength)
        #expect(manager.currentTime >= manager.songLength - 0.1)
        #expect(manager.isPaused)
        #expect(manager.songQueue.map(\.songName) == ["a", "b"])
    }

    @Test func staleFinishCannotSkipNewPlayerOrResumePausedPlayer() async throws {
        let audio = PlaybackAudioFixture.wav()
        var players: [AVAudioPlayer] = []
        let manager = AudioPlayerManager(playerFactory: { _ in
            let player = try AVAudioPlayer(data: audio)
            players.append(player)
            return player
        }, managesSystemAudio: false)
        defer { stop(manager) }
        manager.reloadQueue(newContext: .all, shuffle: false, songs: songs("a", "b", "c"))
        manager.musicPlayPause()
        let old = try #require(players.first)
        manager.skip()
        manager.audioPlayerDidFinishPlaying(old, successfully: true)
        manager.audioPlayerDecodeErrorDidOccur(old, error: CocoaError(.fileReadCorruptFile))
        try await Task.sleep(for: .milliseconds(30))
        #expect(manager.currentSong?.songName == "b")
        #expect(manager.playbackError == nil)
        manager.musicPlayPause()
        let current = try #require(players.last)
        manager.audioPlayerDidFinishPlaying(current, successfully: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(manager.currentSong?.songName == "b")
        #expect(manager.isPaused)
    }

    @Test func genuineFinishAdvancesAndFailureStops() async throws {
        let audio = PlaybackAudioFixture.wav()
        var players: [AVAudioPlayer] = []
        let manager = AudioPlayerManager(playerFactory: { _ in
            let player = try AVAudioPlayer(data: audio)
            players.append(player)
            return player
        }, managesSystemAudio: false)
        defer { stop(manager) }
        manager.reloadQueue(newContext: .all, shuffle: false, songs: songs("a", "b"))
        manager.musicPlayPause()
        let first = try #require(players.last)
        first.stop()
        manager.audioPlayerDidFinishPlaying(first, successfully: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(manager.currentSong?.songName == "b")
        let second = try #require(players.last)
        second.stop()
        manager.audioPlayerDidFinishPlaying(second, successfully: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(manager.currentSong?.songName == "b")
        #expect(manager.isPaused)
        #expect(manager.playbackError != nil)
    }
}

struct SongContextTagTests {
    private func makeSong(locations: [String]) -> Song {
        Song(title: "t", songName: "t", artist: nil,
             locations: locations, populationMin: nil, populationMax: nil)
    }

    @Test func theStoredKeyIsNotTheDisplayedLabel() {
        #expect(MusicContext.gym.storageKey == "gym")
        #expect(MusicContext.gym.displayName == "Gyms")
        #expect(MusicContext.gym.storageKey != MusicContext.gym.displayName)
    }

    @Test func aDisplayNameIsNotAValidStorageKey() {
        #expect(MusicContext(storageKey: "Gyms") == nil)
        #expect(MusicContext(storageKey: "All") == nil)
        #expect(MusicContext(storageKey: "Restaurants") == nil)
    }

    @Test func everyKeyRoundTripsBackToItsContext() {
        let contexts: [MusicContext] = [
            .all, .gym, .restaurant, .store, .park, .home, .work,
            .street, .driving, .beach, .mountain, .city, .town, .water,
            .rainy, .snowy, .traveling
        ]
        for context in contexts { #expect(MusicContext(storageKey: context.storageKey) == context) }
        #expect(Set(contexts.map(\.storageKey)).count == contexts.count)
    }

    @Test func taggingWritesTheKeyAndReadsBackAsTheContext() {
        let song = makeSong(locations: [])
        song.setTagged(.beach, true)
        #expect(song.locations == ["beach"])
        #expect(song.isTagged(.beach))
        #expect(song.taggedContexts == [.beach])
    }

    @Test func taggingIsIdempotentInBothDirections() {
        let song = makeSong(locations: ["gym", "gym"])
        song.setTagged(.gym, true)
        #expect(song.locations == ["gym", "gym"])
        song.setTagged(.gym, false)
        #expect(song.locations.isEmpty)
        song.setTagged(.gym, false)
        #expect(song.locations.isEmpty)
    }

    @Test func aTagThatNamesNoContextSurvivesButMatchesNothing() {
        let song = makeSong(locations: ["gym", "location", "Beaches"])
        #expect(song.taggedContexts == [.gym])
        #expect(!song.isTagged(.beach))
        #expect(song.locations == ["gym", "location", "Beaches"])
        song.setTagged(.park, true)
        #expect(song.locations == ["gym", "location", "Beaches", "park"])
    }
}
