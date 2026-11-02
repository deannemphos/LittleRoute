import Testing
import Foundation
import AVFoundation
import SwiftData
@testable import LittleRoute

@MainActor
private struct ImportFixture {
    let container: ModelContainer
    let context: ModelContext
    let root: URL
    let music: URL
    let sources: URL

    init() throws {
        container = try ModelContainer(for: Song.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LittleRouteTests-\(UUID().uuidString)", isDirectory: true)
        music = root.appendingPathComponent("Music", isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    func source(_ name: String, data: Data = PlaybackAudioFixture.mp3()) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func seed(_ name: String = "track", imported: Bool = true) throws -> Song {
        let song = Song(title: "Original title", songName: name, artist: "Original artist",
                        locations: ["gym", "legacy-tag"], populationMin: 0,
                        populationMax: 1_000, isImported: imported)
        context.insert(song)
        try context.save()
        return song
    }

    func storedSongs() throws -> [Song] {
        try ModelContext(container).fetch(FetchDescriptor<Song>())
    }

    func cleanup(_ manager: AudioPlayerManager) {
        manager.reloadQueue(newContext: .all, shuffle: false, songs: [])
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not clean test audio: \(error)") }
    }

    func manager(failingSave: Bool = false, beforeSave: (() -> Void)? = nil) -> AudioPlayerManager {
        AudioPlayerManager(musicDirectory: music, managesSystemAudio: false, saveChanges: { writer in
            beforeSave?()
            if failingSave { throw CocoaError(.fileWriteNoPermission) }
            try writer.save()
        })
    }
}

@MainActor
@Suite(.serialized)
struct LibraryImportTests {
    @Test func generatedMP3FixtureDecodesWithFileAndAssetAPIs() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let source = try fixture.source("silence.mp3")
        let player = try AVAudioPlayer(contentsOf: source)
        #expect(player.prepareToPlay())
        #expect(player.duration > 7.9 && player.duration < 8.1)
        let asset = AVURLAsset(url: source)
        #expect(try await asset.load(.isPlayable))
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 7.9 && duration.seconds < 8.1)
    }

    @Test func importsValidAudioAndPreservesEmbeddedMP3InBasename() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let source = try fixture.source("mix.mp3.edit.MP3")
        await manager.importSongs(from: [source], modelContext: fixture.context)
        try #require(manager.importReport?.contains("1 imported") == true,
                     "\(manager.importReport ?? "No import report")")
        let song = try #require(try fixture.storedSongs().first)
        #expect(song.songName == "mix.mp3.edit")
        #expect(song.isImported)
        #expect(song.locations == ["all"])
        #expect(AudioPlayerManager.url(for: song, in: fixture.music)?.lastPathComponent == "mix.mp3.edit.mp3")
        #expect(manager.currentSong?.songName == "mix.mp3.edit")
        #expect(manager.songLength > 0)
        #expect(manager.isPaused)
        #expect(!manager.isImporting)
        #expect(manager.importProgress == 1)
        #expect(manager.importReport?.contains("1 imported") == true)
        #expect(manager.importReport?.contains("0 failed") == true)
    }

    @Test func duplicateSkipsWithoutChangingFileTagsOrUnrelatedEdits() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let song = try fixture.seed()
        let original = PlaybackAudioFixture.mp3()
        let destination = fixture.music.appendingPathComponent("track.mp3")
        try original.write(to: destination)
        song.title = "An unrelated unsaved edit"
        let source = try fixture.source("track.mp3", data: PlaybackAudioFixture.mp3(seconds: 2))
        await manager.importSongs(from: [source], modelContext: fixture.context)
        #expect(try Data(contentsOf: destination) == original)
        let stored = try #require(try fixture.storedSongs().first)
        #expect(stored.locations == ["gym", "legacy-tag"])
        #expect(stored.title == "Original title")
        #expect(song.title == "An unrelated unsaved edit")
        #expect(manager.importReport?.contains("1 duplicates skipped") == true)
    }

    @Test func explicitlyReplacingKeepsTagsAndAtomicallyInstallsAudio() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        _ = try fixture.seed()
        let destination = fixture.music.appendingPathComponent("track.mp3")
        try PlaybackAudioFixture.mp3().write(to: destination)
        let replacement = PlaybackAudioFixture.mp3(seconds: 2)
        let source = try fixture.source("track.mp3", data: replacement)
        await manager.importSongs(from: [source], modelContext: fixture.context, replacingExisting: true)
        try #require(manager.importReport?.contains("1 replaced/repaired") == true,
                     "\(manager.importReport ?? "No import report")")
        #expect(try Data(contentsOf: destination) == replacement)
        #expect(try fixture.storedSongs().count == 1)
        #expect(try fixture.storedSongs().first?.locations == ["gym", "legacy-tag"])
        #expect(manager.importReport?.contains("1 replaced/repaired") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.music.path) == ["track.mp3"])
    }

    @Test func replacingLoadedFileReloadsThatSongInsteadOfJumpingToQueueStart() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let first = try fixture.seed("first")
        let selected = try fixture.seed("selected")
        first.locations = ["all"]
        selected.locations = ["all"]
        try fixture.context.save()
        for name in ["first", "selected"] {
            try PlaybackAudioFixture.mp3().write(to: fixture.music.appendingPathComponent("\(name).mp3"))
        }
        manager.reloadQueue(newContext: .all, shuffle: false, songs: [first, selected])
        manager.play(song: selected)
        manager.seek(to: 3)
        let source = try fixture.source("selected.mp3", data: PlaybackAudioFixture.mp3(seconds: 2))
        await manager.importSongs(from: [source], modelContext: fixture.context, replacingExisting: true)
        #expect(manager.currentSong?.songName == "selected")
        #expect(manager.songLength > 1.9 && manager.songLength < 2.1)
        #expect(!manager.isPaused)
        #expect(manager.playbackError == nil)
        #expect(manager.importReport?.contains("1 replaced/repaired") == true)
    }

    @Test func importingAnotherSongPreservesLoadedPlayerTimeAndLatestPause() async throws {
        let fixture = try ImportFixture()
        var pauseBeforeCommit: (() -> Void)?
        let manager = fixture.manager(beforeSave: { pauseBeforeCommit?() })
        defer { fixture.cleanup(manager) }
        let selected = try fixture.seed("selected")
        selected.locations = ["all"]
        try fixture.context.save()
        try PlaybackAudioFixture.mp3().write(to: fixture.music.appendingPathComponent("selected.mp3"))
        manager.reloadQueue(newContext: .all, shuffle: false, songs: [selected])
        manager.musicPlayPause()
        manager.seek(to: 3)
        let seekTime = manager.currentTime
        #expect(abs(seekTime - 3) < 0.05)
        let source = try fixture.source("new.mp3")
        var pausedTime: TimeInterval = 0
        pauseBeforeCommit = {
            manager.musicPlayPause()
            pausedTime = manager.currentTime
        }
        await manager.importSongs(from: [source], modelContext: fixture.context)
        pauseBeforeCommit = nil
        #expect(manager.currentSong?.songName == "selected")
        #expect(pausedTime >= seekTime)
        #expect(abs(manager.currentTime - pausedTime) < 0.01)
        #expect(manager.isPaused)
        #expect(Set(manager.songQueue.map(\.songName)) == ["selected", "new"])
    }

    @Test func bundledNameCollisionSelectsImportedSourceWithoutDiscardingTags() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        _ = try fixture.seed(imported: false)
        let source = try fixture.source("track.mp3")
        await manager.importSongs(from: [source], modelContext: fixture.context)
        try #require(manager.importReport?.contains("1 replaced/repaired") == true,
                     "\(manager.importReport ?? "No import report")")
        let song = try #require(try fixture.storedSongs().first)
        #expect(song.isImported)
        #expect(song.locations == ["gym", "legacy-tag"])
        #expect(AudioPlayerManager.url(for: song, in: fixture.music) == fixture.music.appendingPathComponent("track.mp3"))
        try FileManager.default.removeItem(at: fixture.music.appendingPathComponent("track.mp3"))
        #expect(AudioPlayerManager.url(for: song, in: fixture.music) == nil)
    }

    @Test func failedCopyAndCorruptAudioLeaveExistingFileAndModelUntouched() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        _ = try fixture.seed()
        let original = PlaybackAudioFixture.mp3()
        let destination = fixture.music.appendingPathComponent("track.mp3")
        try original.write(to: destination)
        let missing = fixture.sources.appendingPathComponent("track.mp3")
        await manager.importSongs(from: [missing], modelContext: fixture.context, replacingExisting: true)
        #expect(manager.importReport?.contains("1 failed") == true)
        #expect(try Data(contentsOf: destination) == original)
        let corrupt = try fixture.source("track.mp3", data: Data("not audio".utf8))
        await manager.importSongs(from: [corrupt], modelContext: fixture.context, replacingExisting: true)
        #expect(manager.importReport?.contains("1 failed") == true)
        #expect(try Data(contentsOf: destination) == original)
        #expect(try fixture.storedSongs().first?.title == "Original title")
        #expect(try fixture.storedSongs().first?.locations == ["gym", "legacy-tag"])
    }

    @Test func failedReplacementSaveRestoresOriginalFileAndOnlyItsOwnModelChanges() async throws {
        let fixture = try ImportFixture()
        var attemptedSave = false
        let manager = fixture.manager(failingSave: true, beforeSave: { attemptedSave = true })
        defer { fixture.cleanup(manager) }
        let song = try fixture.seed()
        song.title = "Keep this unrelated pending edit"
        let original = PlaybackAudioFixture.mp3()
        let destination = fixture.music.appendingPathComponent("track.mp3")
        try original.write(to: destination)
        let source = try fixture.source("track.mp3", data: PlaybackAudioFixture.mp3(seconds: 2))
        await manager.importSongs(from: [source], modelContext: fixture.context, replacingExisting: true)
        #expect(attemptedSave, "\(manager.importReport ?? "No import report")")
        #expect(manager.importReport?.contains("1 failed") == true)
        #expect(manager.importReport?.contains("0 replaced/repaired") == true)
        #expect(try Data(contentsOf: destination) == original)
        #expect(try fixture.storedSongs().first?.title == "Original title")
        #expect(song.title == "Keep this unrelated pending edit")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.music.path) == ["track.mp3"])
    }

    @Test func failedNewSongSaveRemovesOnlyTheUncommittedCopy() async throws {
        let fixture = try ImportFixture()
        var attemptedSave = false
        let manager = fixture.manager(failingSave: true, beforeSave: { attemptedSave = true })
        defer { fixture.cleanup(manager) }
        _ = try fixture.seed("unrelated")
        let source = try fixture.source("new.mp3")
        await manager.importSongs(from: [source], modelContext: fixture.context)
        #expect(attemptedSave, "\(manager.importReport ?? "No import report")")
        #expect(manager.importReport?.contains("1 failed") == true)
        #expect(try fixture.storedSongs().map(\.songName) == ["unrelated"])
        #expect(!FileManager.default.fileExists(atPath: fixture.music.appendingPathComponent("new.mp3").path))
    }

    @Test func aFailedItemDoesNotRollBackEarlierSuccessfulImports() async throws {
        let fixture = try ImportFixture()
        let manager = AudioPlayerManager(musicDirectory: fixture.music, managesSystemAudio: false,
                                         saveChanges: { writer in
            if try writer.fetch(FetchDescriptor<Song>()).contains(where: { $0.songName == "rejected" }) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try writer.save()
        })
        defer { fixture.cleanup(manager) }
        let first = try fixture.source("first.mp3")
        let rejected = try fixture.source("rejected.mp3")
        let last = try fixture.source("last.mp3")
        await manager.importSongs(from: [first, rejected, last], modelContext: fixture.context)
        #expect(Set(try fixture.storedSongs().map(\.songName)) == ["first", "last"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.music.path)) == ["first.mp3", "last.mp3"])
        #expect(manager.importReport?.contains("2 imported") == true)
        #expect(manager.importReport?.contains("1 failed") == true)
        #expect(Set(manager.songQueue.map(\.songName)) == ["first", "last"])
    }

    @Test func overlappingRequestsAreSerializedAndSeePreviousDuplicates() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let source = try fixture.source("track.mp3")
        let first = Task { @MainActor in
            await manager.importSongs(from: [source], modelContext: fixture.context)
        }
        let second = Task { @MainActor in
            await manager.importSongs(from: [source], modelContext: fixture.context)
        }
        await first.value
        await second.value
        try #require(manager.importReport?.contains("1 duplicates skipped") == true,
                     "\(manager.importReport ?? "No import report")")
        #expect(try fixture.storedSongs().count == 1)
        #expect(manager.importReport?.contains("1 duplicates skipped") == true)
        #expect(!manager.isImporting)
        #expect(manager.importProgress == 1)
    }

    @Test func caseCollisionDoesNotCreateTwoRecordsForOneFile() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        _ = try fixture.seed("track")
        let source = try fixture.source("TRACK.mp3")
        await manager.importSongs(from: [source], modelContext: fixture.context)
        #expect(try fixture.storedSongs().count == 1)
        #expect(manager.importReport?.contains("Rename the file") == true)
    }

    @Test func successfulDeleteRemovesOnlySelectedImportedSongAndRefreshesFullQueue() throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let selected = try fixture.seed("selected")
        let other = try fixture.seed("other")
        other.locations = ["all"]
        try fixture.context.save()
        let selectedFile = fixture.music.appendingPathComponent("selected.mp3")
        let otherFile = fixture.music.appendingPathComponent("other.mp3")
        try PlaybackAudioFixture.mp3().write(to: selectedFile)
        try PlaybackAudioFixture.mp3().write(to: otherFile)
        #expect(manager.deleteImportedSong(selected, modelContext: fixture.context))
        #expect(try fixture.storedSongs().map(\.songName) == ["other"])
        #expect(!FileManager.default.fileExists(atPath: selectedFile.path))
        #expect(FileManager.default.fileExists(atPath: otherFile.path))
        #expect(manager.songQueue.map(\.songName) == ["other"])
        #expect(manager.currentSong?.songName == "other")
    }

    @Test func failedDeleteSaveRestoresAudioAndKeepsEntryAndUnrelatedPendingEdits() throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager(failingSave: true)
        defer { fixture.cleanup(manager) }
        let selected = try fixture.seed()
        let unrelated = try fixture.seed("unrelated")
        unrelated.title = "Do not roll this back"
        let file = fixture.music.appendingPathComponent("track.mp3")
        let audio = PlaybackAudioFixture.mp3()
        try audio.write(to: file)
        #expect(!manager.deleteImportedSong(selected, modelContext: fixture.context))
        #expect(try fixture.storedSongs().count == 2)
        #expect(try Data(contentsOf: file) == audio)
        #expect(unrelated.title == "Do not roll this back")
        #expect(manager.importReport?.contains("Could not delete") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.music.path) == ["track.mp3"])
    }

    @Test func deletingAnotherSongPreservesPausedPlayerAndPlayhead() throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let selected = try fixture.seed("selected")
        let deleted = try fixture.seed("deleted")
        selected.locations = ["all"]
        deleted.locations = ["all"]
        try fixture.context.save()
        for name in ["selected", "deleted"] {
            try PlaybackAudioFixture.mp3().write(to: fixture.music.appendingPathComponent("\(name).mp3"))
        }
        manager.reloadQueue(newContext: .all, shuffle: false, songs: [selected, deleted])
        manager.seek(to: 3)
        let pausedTime = manager.currentTime
        #expect(abs(pausedTime - 3) < 0.05)
        #expect(manager.deleteImportedSong(deleted, modelContext: fixture.context))
        #expect(manager.currentSong?.songName == "selected")
        #expect(abs(manager.currentTime - pausedTime) < 0.01)
        #expect(manager.isPaused)
        #expect(manager.songQueue.map(\.songName) == ["selected"])
    }

    @Test func deletingAnAlreadyMissingFileStillRemovesTheStoredSong() throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let selected = try fixture.seed()
        #expect(manager.deleteImportedSong(selected, modelContext: fixture.context))
        #expect(try fixture.storedSongs().isEmpty)
        #expect(manager.songQueue.isEmpty)
        #expect(manager.currentSong == nil)
        #expect(manager.isPaused)
    }

    @Test func bundledOnlyRecordsCannotBeDeletedByImportDeletion() throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let bundled = try fixture.seed(imported: false)
        #expect(!manager.deleteImportedSong(bundled, modelContext: fixture.context))
        #expect(try fixture.storedSongs().count == 1)
        #expect(manager.importReport?.contains("Only imported songs") == true)
    }
}
