import Testing
import Foundation
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

    func source(_ name: String, data: Data = PlaybackAudioFixture.wav()) throws -> URL {
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

    func manager(failingSave: Bool = false) -> AudioPlayerManager {
        AudioPlayerManager(musicDirectory: music, managesSystemAudio: false, saveChanges: { writer in
            if failingSave { throw CocoaError(.fileWriteNoPermission) }
            try writer.save()
        })
    }
}

@MainActor
@Suite(.serialized)
struct LibraryImportTests {
    @Test func importsValidAudioAndPreservesEmbeddedMP3InBasename() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        let source = try fixture.source("mix.mp3.edit.MP3")
        await manager.importSongs(from: [source], modelContext: fixture.context)
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
        let original = PlaybackAudioFixture.wav()
        let destination = fixture.music.appendingPathComponent("track.mp3")
        try original.write(to: destination)
        song.title = "An unrelated unsaved edit"
        let source = try fixture.source("track.mp3", data: PlaybackAudioFixture.wav(seconds: 2))
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
        try PlaybackAudioFixture.wav().write(to: destination)
        let replacement = PlaybackAudioFixture.wav(seconds: 2)
        let source = try fixture.source("track.mp3", data: replacement)
        await manager.importSongs(from: [source], modelContext: fixture.context, replacingExisting: true)
        #expect(try Data(contentsOf: destination) == replacement)
        #expect(try fixture.storedSongs().count == 1)
        #expect(try fixture.storedSongs().first?.locations == ["gym", "legacy-tag"])
        #expect(manager.importReport?.contains("1 replaced/repaired") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.music.path) == ["track.mp3"])
    }

    @Test func bundledNameCollisionSelectsImportedSourceWithoutDiscardingTags() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager()
        defer { fixture.cleanup(manager) }
        _ = try fixture.seed(imported: false)
        let source = try fixture.source("track.mp3")
        await manager.importSongs(from: [source], modelContext: fixture.context)
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
        let original = PlaybackAudioFixture.wav()
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
        let manager = fixture.manager(failingSave: true)
        defer { fixture.cleanup(manager) }
        let song = try fixture.seed()
        song.title = "Keep this unrelated pending edit"
        let original = PlaybackAudioFixture.wav()
        let destination = fixture.music.appendingPathComponent("track.mp3")
        try original.write(to: destination)
        let source = try fixture.source("track.mp3", data: PlaybackAudioFixture.wav(seconds: 2))
        await manager.importSongs(from: [source], modelContext: fixture.context, replacingExisting: true)
        #expect(manager.importReport?.contains("1 failed") == true)
        #expect(manager.importReport?.contains("0 replaced/repaired") == true)
        #expect(try Data(contentsOf: destination) == original)
        #expect(try fixture.storedSongs().first?.title == "Original title")
        #expect(song.title == "Keep this unrelated pending edit")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.music.path) == ["track.mp3"])
    }

    @Test func failedNewSongSaveRemovesOnlyTheUncommittedCopy() async throws {
        let fixture = try ImportFixture()
        let manager = fixture.manager(failingSave: true)
        defer { fixture.cleanup(manager) }
        _ = try fixture.seed("unrelated")
        let source = try fixture.source("new.mp3")
        await manager.importSongs(from: [source], modelContext: fixture.context)
        #expect(manager.importReport?.contains("1 failed") == true)
        #expect(try fixture.storedSongs().map(\.songName) == ["unrelated"])
        #expect(!FileManager.default.fileExists(atPath: fixture.music.appendingPathComponent("new.mp3").path))
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
        try PlaybackAudioFixture.wav().write(to: selectedFile)
        try PlaybackAudioFixture.wav().write(to: otherFile)
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
        let audio = PlaybackAudioFixture.wav()
        try audio.write(to: file)
        #expect(!manager.deleteImportedSong(selected, modelContext: fixture.context))
        #expect(try fixture.storedSongs().count == 2)
        #expect(try Data(contentsOf: file) == audio)
        #expect(unrelated.title == "Do not roll this back")
        #expect(manager.importReport?.contains("Could not delete") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.music.path) == ["track.mp3"])
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
