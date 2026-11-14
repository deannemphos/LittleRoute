import Testing
import Foundation
import AVFoundation
@testable import LittleRoute

/// Generated audio on disk: EnginePlayer reads files, not Data, and the manager
/// resolves imported songs to "<name>.mp3" inside its music directory.
@MainActor
private struct EngineFixture {
    let music: URL

    init() throws {
        music = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnginePlayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
    }

    func track(_ name: String, seconds: Int) throws -> URL {
        let url = music.appendingPathComponent("\(name).mp3")
        try PlaybackAudioFixture.mp3(seconds: seconds).write(to: url)
        return url
    }

    func player(seconds: Int) throws -> EnginePlayer {
        let player = try EnginePlayer(url: try track(UUID().uuidString, seconds: seconds))
        #expect(player.prepareToPlay())
        return player
    }

    func cleanup() {
        do { try FileManager.default.removeItem(at: music) }
        catch { Issue.record("Could not clean test audio: \(error)") }
    }
}

/// The engine path AudioPlayerManager uses in production. Interruptions and
/// route changes depend on the hardware session and stay device checks.
@MainActor
@Suite(.serialized)
struct EnginePlayerTests {
    private func waitUntil(_ attempts: Int = 400, _ condition: () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func pauseHoldsThePositionAndResumeContinuesFromIt() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let player = try fixture.player(seconds: 8)
        defer { player.stop() }
        #expect(player.duration > 7.9 && player.duration < 8.2)
        #expect(player.currentTime == 0)
        #expect(!player.isPlaying)

        #expect(player.play())
        #expect(player.isPlaying)
        try await waitUntil { player.currentTime > 0.2 }
        player.pause()
        #expect(!player.isPlaying)
        let paused = player.currentTime
        #expect(paused > 0.2 && paused < 2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(player.currentTime == paused)

        #expect(player.play())
        #expect(player.isPlaying)
        try await waitUntil { player.currentTime > paused + 0.2 }
        #expect(player.currentTime > paused + 0.2)
        #expect(player.currentTime < paused + 2)
        player.pause()
        player.pause()
        #expect(!player.isPlaying)
    }

    @Test func seekingClampsWhilePausedAndRepositionsWhilePlaying() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let player = try fixture.player(seconds: 8)
        defer { player.stop() }

        player.currentTime = 3
        #expect(player.currentTime == 3)
        #expect(!player.isPlaying)
        player.currentTime = -1
        #expect(player.currentTime == 0)
        player.currentTime = .nan
        #expect(player.currentTime == 0)
        player.currentTime = .infinity
        #expect(player.currentTime == 0)
        player.currentTime = 100
        #expect(player.currentTime == player.duration)

        player.currentTime = 1
        #expect(player.play())
        try await waitUntil { player.currentTime > 1.2 }
        player.currentTime = 5
        #expect(player.isPlaying)
        #expect(player.currentTime >= 5)
        try await waitUntil { player.currentTime > 5.2 }
        #expect(player.currentTime > 5.2 && player.currentTime < 7)
        player.currentTime = 2
        #expect(player.isPlaying)
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.currentTime >= 2 && player.currentTime < 4)
    }

    @Test func playingToTheEndReportsCompletionOnceAndParksAtTheEnd() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let player = try fixture.player(seconds: 1)
        defer { player.stop() }
        var finishes: [Bool] = []
        player.onFinish = { finishes.append($0) }

        #expect(player.play())
        try await waitUntil { !finishes.isEmpty }
        #expect(finishes == [true])
        #expect(!player.isPlaying)
        #expect(player.currentTime == player.duration)
        try await Task.sleep(for: .milliseconds(200))
        #expect(finishes == [true])
    }

    @Test func supersededSchedulesAndStoppedPlayersNeverReportCompletion() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let player = try fixture.player(seconds: 1)
        defer { player.stop() }
        var finishes: [Bool] = []
        player.onFinish = { finishes.append($0) }

        // Seeking and pausing stop the node, which fires the old schedule's
        // completion early; neither may count as reaching the end.
        #expect(player.play())
        try await waitUntil { player.currentTime > 0.1 }
        player.currentTime = 0
        try await Task.sleep(for: .milliseconds(150))
        #expect(finishes.isEmpty)
        #expect(player.isPlaying)
        player.currentTime = player.duration - 0.2
        player.pause()
        try await Task.sleep(for: .milliseconds(400))
        #expect(finishes.isEmpty)
        #expect(!player.isPlaying)
        #expect(player.currentTime < player.duration)

        // Resuming near the end still finishes exactly once.
        #expect(player.play())
        try await waitUntil { !finishes.isEmpty }
        #expect(finishes == [true])

        // A stopped player is terminal: its callback is gone and play() is refused.
        let stopped = try fixture.player(seconds: 1)
        var stoppedFinishes: [Bool] = []
        stopped.onFinish = { stoppedFinishes.append($0) }
        #expect(stopped.play())
        stopped.stop()
        #expect(!stopped.isPlaying)
        #expect(!stopped.play())
        try await Task.sleep(for: .milliseconds(300))
        #expect(stoppedFinishes.isEmpty)
    }

    @Test func fadeReachesTheTargetAndImmediateVolumeCancelsIt() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let player = try fixture.player(seconds: 8)
        defer { player.stop() }
        player.volume = 1
        player.setVolume(0, fadeDuration: 0.1)
        try await waitUntil { player.volume == 0 }
        #expect(player.volume == 0)
        player.setVolume(1, fadeDuration: 0.5)
        player.volume = 0.25
        try await Task.sleep(for: .milliseconds(150))
        #expect(player.volume == 0.25)
    }

    @Test func managerHandsOffToTheNextTrackWhenTheEngineFinishes() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        _ = try fixture.track("a", seconds: 1)
        _ = try fixture.track("b", seconds: 8)
        let library = ["a", "b"].map {
            Song(title: $0, songName: $0, artist: nil, locations: [MusicContext.all.storageKey],
                 populationMin: 0, populationMax: 1_000_000, isImported: true)
        }
        let manager = AudioPlayerManager(musicDirectory: fixture.music, managesSystemAudio: false)
        defer { manager.reloadQueue(newContext: .all, shuffle: false, songs: []) }
        manager.reloadQueue(newContext: .all, shuffle: false, songs: library)
        #expect(manager.currentSong?.songName == "a")
        #expect(manager.songLength > 0.9 && manager.songLength < 1.2)
        #expect(manager.playbackError == nil)

        manager.musicPlayPause()
        #expect(!manager.isPaused)
        try await waitUntil { manager.currentSong?.songName == "b" }
        #expect(manager.currentSong?.songName == "b")
        #expect(!manager.isPaused)
        #expect(manager.songLength > 7.9)
        #expect(manager.playbackError == nil)
        try await waitUntil { manager.currentTime > 0.1 }
        #expect(manager.currentTime > 0.1 && manager.currentTime < 2)

        // The handed-off track pauses and resumes like any other engine player.
        manager.musicPlayPause()
        #expect(manager.isPaused)
        let paused = manager.currentTime
        try await Task.sleep(for: .milliseconds(150))
        #expect(manager.currentTime == paused)
        manager.musicPlayPause()
        #expect(!manager.isPaused)
        #expect(manager.currentSong?.songName == "b")
    }
}
