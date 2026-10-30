import Foundation
import AVFoundation
import MediaPlayer
import Observation
import SwiftData
import os

@MainActor
@Observable
class AudioPlayerManager: NSObject, AVAudioPlayerDelegate {
    var isPaused = true
    var isShuffled = false
    var songLength: TimeInterval = 0
    var currentTime: TimeInterval = 0
    var currentContext: MusicContext = .all
    var currentSong: Song?
    private(set) var songQueue: [Song] = []
    public private(set) var queueSource: MusicContext = .all
    public private(set) var playbackError: String?
    public var importReport: String?
    public private(set) var isImporting = false
    public private(set) var importProgress: Double = 0

    @ObservationIgnored private var orderedQueue: [Song] = []
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var loadedSongName: String?
    @ObservationIgnored private var loadedSource: Bool?
    @ObservationIgnored private var currentIndex: Int?
    @ObservationIgnored private var playbackTimer: Timer?
    @ObservationIgnored private var ticksSinceNowPlayingSync = 0
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var fadingOutPlayerID: ObjectIdentifier?
    @ObservationIgnored private var generation: UInt = 0
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var hasActivatedSession = false
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var pendingImports = 0
    @ObservationIgnored private let playerFactory: ((Song) throws -> AVAudioPlayer)?
    @ObservationIgnored private let musicDirectory: URL
    @ObservationIgnored private let managesSystemAudio: Bool
    @ObservationIgnored private let saveChanges: (ModelContext) throws -> Void

    static let shared = AudioPlayerManager()

    // The factory accepts real AVAudioPlayers so tests can use generated audio,
    // including players that reject prepare/play, without registering system controls.
    init(playerFactory: ((Song) throws -> AVAudioPlayer)? = nil,
         musicDirectory: URL = AudioPlayerManager.importedMusicDirectory,
         managesSystemAudio: Bool = true,
         saveChanges: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.playerFactory = playerFactory
        self.musicDirectory = musicDirectory
        self.managesSystemAudio = managesSystemAudio
        self.saveChanges = saveChanges
        super.init()
        if managesSystemAudio {
            configureAudioSession()
            observeAudioSessionEvents()
            setupRemoteCommands()
        }
    }

    var progress: Double {
        guard songLength > 0 else { return 0 }
        return min(1, max(0, currentTime / songLength))
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            playbackError = "Audio setup failed. Try playing again: \(error.localizedDescription)"
            Log.playback.error("Audio setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func activateSession() -> Bool {
        guard managesSystemAudio else { return true }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            hasActivatedSession = true
            return true
        } catch {
            playbackError = "Cannot start audio. Try again: \(error.localizedDescription)"
            return false
        }
    }

    private func deactivateSession() {
        guard hasActivatedSession else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            hasActivatedSession = false
        } catch {
            playbackError = "Could not release the audio session: \(error.localizedDescription)"
        }
    }

    private func observeAudioSessionEvents() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: session)
        center.addObserver(self, selector: #selector(handleRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification, object: session)
    }

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                let wasPlaying = !self.isPaused && self.audioPlayer != nil
                self.cancelTransition()
                self.wasPlayingBeforeInterruption = wasPlaying
                self.pauseLoadedSong()
            case .ended:
                guard self.wasPlayingBeforeInterruption else { return }
                self.wasPlayingBeforeInterruption = false
                guard shouldResume else { return }
                self.settleQueue(keepCurrentSong: true, autoplay: true)
            @unknown default:
                break
            }
        }
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in
            self?.cancelTransition()
            self?.pauseLoadedSong()
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPaused else { return }
                self.musicPlayPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelTransition()
                self.pauseLoadedSong()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.musicPlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skip() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite else { return .commandFailed }
            let position = event.positionTime
            DispatchQueue.main.async { self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard managesSystemAudio else { return }
        guard let currentSong, let audioPlayer else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentSong.title,
            MPMediaItemPropertyArtist: currentSong.artist ?? "Unknown Artist",
            MPMediaItemPropertyPlaybackDuration: songLength,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: audioPlayer.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0
        ]
    }

    private func cancelTransition() {
        generation &+= 1
        transitionTask?.cancel()
        transitionTask = nil
        fadingOutPlayerID = nil
        audioPlayer?.setVolume(1, fadeDuration: 0)
        wasPlayingBeforeInterruption = false
    }

    private func resolveQueue(context: MusicContext, shuffle: Bool, songs: [Song]) {
        currentContext = context
        isShuffled = shuffle
        let exact = songs.filter { $0.isTagged(context) }
        queueSource = exact.isEmpty ? .all : context
        orderedQueue = exact.isEmpty ? songs.filter { $0.isTagged(.all) } : exact
        songQueue = shuffle ? orderedQueue.shuffled() : orderedQueue
        currentIndex = matchingCurrentIndex()
    }

    private func matchingCurrentIndex() -> Int? {
        guard let loadedSongName, audioPlayer != nil else { return nil }
        return songQueue.firstIndex {
            $0.songName == loadedSongName && $0.isImported == loadedSource
        }
    }

    public func reloadQueue(newContext: MusicContext, shuffle: Bool, songs: [Song],
                            keepCurrentSong: Bool = true) {
        let wasPlaying = !isPaused
        cancelTransition()
        resolveQueue(context: newContext, shuffle: shuffle, songs: songs)
        settleQueue(keepCurrentSong: keepCurrentSong, autoplay: wasPlaying)
    }

    private func settleQueue(keepCurrentSong: Bool, autoplay: Bool) {
        guard !songQueue.isEmpty else {
            clearPlayer()
            playbackError = nil
            deactivateSession()
            return
        }
        if keepCurrentSong, let index = matchingCurrentIndex() {
            currentIndex = index
            currentSong = songQueue[index]
            if autoplay && isPaused { playLoadedSong() }
            updateNowPlayingInfo()
            return
        }
        if loadSong(at: 0), autoplay { playLoadedSong() }
    }

    // One fade-out/fade-in, never two audible players. No delayed closure owns a
    // library snapshot: every reload invalidates this generation and resolves afresh.
    public func switchContext(to newContext: MusicContext, songs: [Song],
                              fadeDuration: TimeInterval = 1.5) {
        let wasPlaying = !isPaused
        cancelTransition()
        resolveQueue(context: newContext, shuffle: isShuffled, songs: songs)
        if matchingCurrentIndex() != nil {
            settleQueue(keepCurrentSong: true, autoplay: wasPlaying)
            return
        }
        guard wasPlaying, let player = audioPlayer, !songQueue.isEmpty else {
            settleQueue(keepCurrentSong: true, autoplay: wasPlaying)
            return
        }
        let duration = fadeDuration.isFinite ? min(30, max(0, fadeDuration)) : 0
        let token = generation
        let playerID = ObjectIdentifier(player)
        fadingOutPlayerID = playerID
        player.setVolume(0, fadeDuration: duration)
        transitionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token,
                  let oldPlayer = self.audioPlayer, ObjectIdentifier(oldPlayer) == playerID,
                  !self.isPaused else { return }
            self.fadingOutPlayerID = nil
            guard self.loadSong(at: 0) else {
                self.transitionTask = nil
                return
            }
            self.audioPlayer?.volume = 0
            guard self.playLoadedSong(), let nextPlayer = self.audioPlayer else {
                self.audioPlayer?.volume = 1
                self.transitionTask = nil
                return
            }
            let nextID = ObjectIdentifier(nextPlayer)
            nextPlayer.setVolume(1, fadeDuration: duration)
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard !Task.isCancelled, self.generation == token,
                  let current = self.audioPlayer, ObjectIdentifier(current) == nextID else { return }
            current.volume = 1
            self.transitionTask = nil
        }
    }

    public func startPlaybackIfNothingElseIsPlaying() {
        guard !songQueue.isEmpty, isPaused else { return }
        guard !managesSystemAudio || !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }
        musicPlayPause()
    }

    public func musicPlayPause() {
        cancelTransition()
        if !isPaused {
            pauseLoadedSong()
        } else {
            if matchingCurrentIndex() == nil {
                guard !songQueue.isEmpty, loadSong(at: currentIndex ?? 0) else { return }
            }
            playLoadedSong()
        }
    }

    private func pauseLoadedSong() {
        audioPlayer?.pause()
        currentTime = audioPlayer?.currentTime ?? 0
        isPaused = true
        stopPlaybackTimer()
        updateNowPlayingInfo()
    }

    @discardableResult
    private func playLoadedSong() -> Bool {
        guard let player = audioPlayer else { return false }
        guard activateSession() else {
            pauseLoadedSong()
            return false
        }
        guard player.play() else {
            playbackError = "Cannot play “\(currentSong?.title ?? "this song")”. Try again or reimport the file."
            pauseLoadedSong()
            return false
        }
        playbackError = nil
        isPaused = false
        startPlaybackTimer()
        updateNowPlayingInfo()
        return true
    }

    public func skip() {
        cancelTransition()
        guard !songQueue.isEmpty else { return }
        let next = currentIndex.map { ($0 + 1) % songQueue.count } ?? 0
        if loadSong(at: next) { playLoadedSong() }
    }

    public func previous() {
        cancelTransition()
        guard !songQueue.isEmpty else { return }
        let previous = currentIndex.map { ($0 - 1 + songQueue.count) % songQueue.count } ?? 0
        if loadSong(at: previous) { playLoadedSong() }
    }

    public func play(song: Song) {
        cancelTransition()
        guard let index = songQueue.firstIndex(where: { $0.songName == song.songName }) else { return }
        if loadSong(at: index) { playLoadedSong() }
    }

    public func toggleShuffle() {
        let wasPlaying = !isPaused
        cancelTransition()
        isShuffled.toggle()
        songQueue = isShuffled ? orderedQueue.shuffled() : orderedQueue
        currentIndex = matchingCurrentIndex()
        settleQueue(keepCurrentSong: true, autoplay: wasPlaying)
    }

    public func seek(to time: TimeInterval) {
        guard time.isFinite, let player = audioPlayer else { return }
        cancelTransition()
        player.currentTime = min(songLength, max(0, time))
        currentTime = player.currentTime
        updateNowPlayingInfo()
    }

    @discardableResult
    private func loadSong(at index: Int) -> Bool {
        guard songQueue.indices.contains(index) else { return false }
        let song = songQueue[index]
        do {
            let prepared: AVAudioPlayer
            if let playerFactory {
                prepared = try playerFactory(song)
            } else {
                guard let url = Self.url(for: song, in: musicDirectory) else {
                    throw LibraryFailure("The audio file is missing. Reimport it from Files.")
                }
                prepared = try AVAudioPlayer(contentsOf: url)
            }
            guard prepared.prepareToPlay(), prepared.duration.isFinite, prepared.duration > 0 else {
                throw LibraryFailure("The audio file could not be prepared. Reimport a valid audio file.")
            }
            clearPlayer()
            prepared.delegate = self
            audioPlayer = prepared
            currentSong = song
            loadedSongName = song.songName
            loadedSource = song.isImported
            currentIndex = index
            songLength = prepared.duration
            currentTime = prepared.currentTime
            playbackError = nil
            updateNowPlayingInfo()
            return true
        } catch {
            clearPlayer()
            currentIndex = index
            playbackError = "Cannot load “\(song.title)”: \(error.localizedDescription)"
            Log.playback.error("Audio load failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func clearPlayer() {
        stopPlaybackTimer()
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        loadedSongName = nil
        loadedSource = nil
        currentSong = nil
        currentIndex = nil
        isPaused = true
        currentTime = 0
        songLength = 0
        updateNowPlayingInfo()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self, weak player] in
            guard let self, let player, self.audioPlayer === player, !self.isPaused,
                  !player.isPlaying, self.fadingOutPlayerID != ObjectIdentifier(player) else { return }
            if flag {
                self.skip()
            } else {
                self.cancelTransition()
                self.playbackError = "Playback stopped unexpectedly. Try again or reimport this song."
                self.pauseLoadedSong()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "The audio file could not be decoded."
        DispatchQueue.main.async { [weak self, weak player] in
            guard let self, let player, self.audioPlayer === player else { return }
            self.cancelTransition()
            self.playbackError = "\(message) Reimport this song."
            self.pauseLoadedSong()
        }
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        ticksSinceNowPlayingSync = 0
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.stopPlaybackTimer()
                    // The finish delegate owns advancement; a timer tick must not
                    // turn its still-current playback intent into a user pause.
                    return
                }
                self.ticksSinceNowPlayingSync += 1
                if self.ticksSinceNowPlayingSync >= 10 {
                    self.ticksSinceNowPlayingSync = 0
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    // MARK: Library files and transactions

    nonisolated static var importedMusicDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
    }

    nonisolated private static func importedURL(named name: String, in directory: URL) -> URL? {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return nil }
        return directory.appendingPathComponent("\(name).mp3")
    }

    nonisolated private static func bundledURL(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Music")
    }

    public static func url(for song: Song) -> URL? {
        url(for: song, in: importedMusicDirectory)
    }

    static func url(for song: Song, in directory: URL) -> URL? {
        guard song.isImported else { return bundledURL(named: song.songName) }
        guard let url = importedURL(named: song.songName, in: directory),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // Compatibility only: callers with a Song should use the source-aware overload.
    nonisolated static func url(forSongFile songName: String) -> URL? {
        if let bundled = bundledURL(named: songName) { return bundled }
        guard let imported = importedURL(named: songName, in: importedMusicDirectory),
              FileManager.default.fileExists(atPath: imported.path) else { return nil }
        return imported
    }

    public func loadSongsFromBundle(modelContext: ModelContext) -> [Song] {
        let writer = ModelContext(modelContext.container)
        writer.autosaveEnabled = false
        do {
            guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Music", isDirectory: true) else {
                throw LibraryFailure("Bundled Music folder is unavailable.")
            }
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "mp3" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var byName = try existingSongsByName(in: writer)
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                if byName[name] != nil { continue }
                let song = makeImportedSong(name: name, title: name, artist: "Unknown Artist")
                song.isImported = false
                writer.insert(song)
                byName[name] = song
            }
            try saveChanges(writer)
            return Array(byName.values).sorted { $0.songName < $1.songName }
        } catch {
            writer.rollback()
            importReport = "Could not load the bundled library. Reopen LittleRoute to retry: \(error.localizedDescription)"
            return []
        }
    }

    public func importSongs(from urls: [URL], modelContext: ModelContext,
                            replacingExisting: Bool = false) async {
        let previous = importTask
        pendingImports += 1
        isImporting = true
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performImport(from: urls, container: modelContext.container,
                                     replacingExisting: replacingExisting)
        }
        importTask = task
        await task.value
        pendingImports -= 1
        if pendingImports == 0 {
            importTask = nil
            isImporting = false
        }
    }

    private struct ImportSummary {
        var imported = 0
        var replaced = 0
        var skipped = 0
        var failures: [String] = []
        var notes: [String] = []
        var text: String {
            (["\(imported) imported, \(replaced) replaced/repaired, \(skipped) duplicates skipped, \(failures.count) failed."]
             + failures + notes).joined(separator: "\n")
        }
    }

    private func performImport(from urls: [URL], container: ModelContainer, replacingExisting: Bool) async {
        var summary = ImportSummary()
        var changedFiles: Set<String> = []
        importProgress = 0
        importReport = "Importing \(urls.count) file(s)…"
        let writer = ModelContext(container)
        writer.autosaveEnabled = false
        do {
            try FileManager.default.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
            var byName = try existingSongsByName(in: writer)
            for (index, source) in urls.enumerated() {
                defer { importProgress = Double(index + 1) / Double(urls.count) }
                let name = source.deletingPathExtension().lastPathComponent
                guard source.pathExtension.lowercased() == "mp3",
                      let destination = Self.importedURL(named: name, in: musicDirectory) else {
                    summary.failures.append("\(source.lastPathComponent): Choose an MP3 with a valid filename.")
                    continue
                }
                if let collision = byName.keys.first(where: { $0 != name && $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    summary.failures.append("\(name): The filename conflicts with “\(collision)”. Rename the file before importing.")
                    continue
                }
                let existing = byName[name]
                if existing?.isImported == true,
                   FileManager.default.fileExists(atPath: destination.path), !replacingExisting {
                    summary.skipped += 1
                    summary.notes.append("\(name): Duplicate skipped; existing audio and tags kept.")
                    continue
                }
                let accessing = source.startAccessingSecurityScopedResource()
                defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                let staged = musicDirectory.appendingPathComponent(".import-\(UUID().uuidString).mp3")
                var backup: URL?
                var installed = false
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Self.coordinatedCopy(from: source, to: staged)
                        let player = try AVAudioPlayer(contentsOf: staged)
                        guard player.prepareToPlay(), player.duration > 0 else {
                            throw LibraryFailure("This file is not playable audio.")
                        }
                    }.value
                    let metadata = await Self.readMetadata(at: staged, fallback: name)
                    backup = try Self.installStagedFile(staged, at: destination)
                    installed = true
                    let song = existing ?? makeImportedSong(name: name, title: metadata.title, artist: metadata.artist)
                    if existing == nil { writer.insert(song) }
                    song.isImported = true
                    song.title = metadata.title
                    song.artist = metadata.artist
                    try saveChanges(writer)
                    byName[name] = song
                    changedFiles.insert(name)
                    if existing == nil { summary.imported += 1 } else { summary.replaced += 1 }
                    if let backup { Self.removeFile(backup, notes: &summary.notes) }
                    if let warning = metadata.warning { summary.notes.append("\(name): \(warning)") }
                } catch {
                    writer.rollback()
                    var message = "\(name): \(error.localizedDescription) Try importing again."
                    if installed {
                        do { try Self.restoreFile(at: destination, backup: backup) }
                        catch {
                            message += " Recovery failed: \(error.localizedDescription). Keep \(backup?.lastPathComponent ?? destination.lastPathComponent) for recovery."
                        }
                    }
                    Self.removeFile(staged, notes: &summary.notes)
                    summary.failures.append(message)
                    // A rollback invalidates this context's previous object snapshots.
                    byName = try existingSongsByName(in: writer)
                }
            }
            if summary.imported + summary.replaced > 0 {
                let songs = try writer.fetch(FetchDescriptor<Song>())
                reloadQueue(newContext: currentContext, shuffle: isShuffled, songs: songs,
                            keepCurrentSong: !changedFiles.contains(loadedSongName ?? ""))
            }
        } catch {
            summary.failures.append("Library could not be read or updated: \(error.localizedDescription). Import stopped; review the item results and reopen LittleRoute before retrying.")
        }
        if summary.skipped > 0 {
            summary.notes.append("Existing imported files and tags were kept. Use Replace Matching Imports in My Music to replace their audio.")
        }
        importProgress = 1
        importReport = summary.text
    }

    private func makeImportedSong(name: String, title: String, artist: String) -> Song {
        let song = Song(title: title, songName: name, artist: artist,
                        locations: [MusicContext.all.storageKey], populationMin: 0,
                        populationMax: 10_000_000, isImported: true)
        // Song's legacy initializer strips every ".mp3"; only the final extension
        // belongs to the importer, so restore the exact basename here.
        song.songName = name
        return song
    }

    private func existingSongsByName(in context: ModelContext) throws -> [String: Song] {
        let songs = try context.fetch(FetchDescriptor<Song>())
        return Dictionary(songs.map { ($0.songName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated private static func readMetadata(at url: URL, fallback: String) async
        -> (title: String, artist: String, warning: String?) {
        do {
            let metadata = try await AVURLAsset(url: url).load(.commonMetadata)
            var title = fallback
            var artist = "Unknown Artist"
            if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first,
               let value = try await item.load(.stringValue), !value.isEmpty { title = value }
            if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first,
               let value = try await item.load(.stringValue), !value.isEmpty { artist = value }
            return (title, artist, nil)
        } catch {
            return (fallback, "Unknown Artist", "Audio imported; tags could not be read, so the filename is used.")
        }
    }

    nonisolated private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading, error: &coordinatorError) { url in
            do { try FileManager.default.copyItem(at: url, to: destination) }
            catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
    }

    nonisolated private static func installStagedFile(_ staged: URL, at destination: URL) throws -> URL? {
        let files = FileManager.default
        guard files.fileExists(atPath: destination.path) else {
            try files.moveItem(at: staged, to: destination)
            return nil
        }
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".recovery-\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            _ = try files.replaceItemAt(destination, withItemAt: staged, backupItemName: backup.lastPathComponent,
                                       options: .withoutDeletingBackupItem)
        } catch {
            let replacementError = error
            if files.fileExists(atPath: backup.path) {
                do { try restoreFile(at: destination, backup: backup) }
                catch {
                    throw LibraryFailure("Replacement failed: \(replacementError.localizedDescription). Recovery failed: \(error.localizedDescription). Keep \(backup.lastPathComponent) for recovery.")
                }
            }
            throw replacementError
        }
        return backup
    }

    nonisolated private static func restoreFile(at destination: URL, backup: URL?) throws {
        let files = FileManager.default
        if let backup {
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: backup)
            } else {
                try files.moveItem(at: backup, to: destination)
            }
        } else {
            try files.removeItem(at: destination)
        }
    }

    nonisolated private static func removeFile(_ file: URL, notes: inout [String]) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { try FileManager.default.removeItem(at: file) }
        catch { notes.append("Could not remove \(file.lastPathComponent): \(error.localizedDescription). The recovery copy is safe to keep.") }
    }

    @discardableResult
    public func deleteImportedSong(_ song: Song, modelContext: ModelContext) -> Bool {
        guard !isImporting else {
            importReport = "Wait for importing to finish before deleting a song."
            return false
        }
        let writer = ModelContext(modelContext.container)
        writer.autosaveEnabled = false
        var recovery: URL?
        var destination: URL?
        do {
            let songs = try writer.fetch(FetchDescriptor<Song>())
            guard let stored = songs.first(where: { $0.songName == song.songName }), stored.isImported,
                  let file = Self.importedURL(named: stored.songName, in: musicDirectory) else {
                throw LibraryFailure("Only imported songs can be removed. Reopen My Music and retry.")
            }
            destination = file
            if FileManager.default.fileExists(atPath: file.path) {
                let staged = musicDirectory.appendingPathComponent(".recovery-\(UUID().uuidString)-\(file.lastPathComponent)")
                try FileManager.default.moveItem(at: file, to: staged)
                recovery = staged
            }
            let restoresBundle = Self.bundledURL(named: stored.songName) != nil
            if restoresBundle {
                stored.isImported = false
                stored.title = stored.songName
                stored.artist = "Unknown Artist"
            } else {
                writer.delete(stored)
            }
            try saveChanges(writer)
            var notes: [String] = []
            if let recovery { Self.removeFile(recovery, notes: &notes) }
            importReport = ([restoresBundle ? "Imported copy removed; the bundled song and its tags were kept." : "Song deleted. Import the original file to add it again."] + notes).joined(separator: "\n")
            // Use this successful transaction's complete library, never the UI's search.
            reloadQueue(newContext: currentContext, shuffle: isShuffled,
                        songs: restoresBundle ? songs : songs.filter { $0 !== stored })
            return true
        } catch {
            writer.rollback()
            var message = "Could not delete the song: \(error.localizedDescription). The library entry was kept."
            if let recovery, let destination {
                do { try FileManager.default.moveItem(at: recovery, to: destination) }
                catch { message += " Restore failed: \(error.localizedDescription). Your audio is kept at \(recovery.lastPathComponent); keep that file for recovery." }
            }
            importReport = message
            return false
        }
    }

    public func addSong(title: String, artist: String, modelContext: ModelContext) {
        let writer = ModelContext(modelContext.container)
        writer.autosaveEnabled = false
        do {
            guard try existingSongsByName(in: writer)["filename"] == nil else {
                throw LibraryFailure("The placeholder song already exists. Use Import to add a different audio file.")
            }
            writer.insert(Song(title: title, songName: "filename", artist: artist,
                               locations: [MusicContext.all.storageKey], populationMin: 0, populationMax: 9999))
            try saveChanges(writer)
        } catch {
            writer.rollback()
            importReport = "Could not add the song: \(error.localizedDescription)"
        }
    }
}

private struct LibraryFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
