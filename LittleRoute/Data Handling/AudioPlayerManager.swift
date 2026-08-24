//
//  AudioPlayerManager.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 5/7/25.
//

import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import _SwiftData_SwiftUI

class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    @Published var isPaused: Bool = false
    @Published var isShuffled: Bool = false
    @Published var songLength: TimeInterval = 0.0   // total length of the song
    @Published var currentTime: TimeInterval = 0.0  // current playback time
    @Published var currentContext: MusicContext = .all
    @Published var currentSong: Song? = nil // the currently playing song, if any

    @Published private(set) var songQueue: [Song] = [] // read-only outside; UI observes this for the queue drawer

    private var audioPlayer: AVAudioPlayer?
    private var currentIndex: Int = 0 // index of the current song in the queue
    private var playbackTimer: Timer?
    
    static let shared = AudioPlayerManager()

    private override init() {
        super.init()
        configureAudioSession()
        setupRemoteCommands()
    }

    // Configure the shared audio session for background playback.
    // Requires the "audio" UIBackgroundMode (declared in Info.plist).
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    // Lock screen / Control Center playback controls
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self = self, self.isPaused else { return .commandFailed }
            self.musicPlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, !self.isPaused else { return .commandFailed }
            self.musicPlayPause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.musicPlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.skip()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
    }

    // Publish current song metadata to the lock screen / Control Center
    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentSong?.title ?? "LittleRoute"
        info[MPMediaItemPropertyArtist] = currentSong?.artist ?? "Unknown Artist"
        info[MPMediaItemPropertyPlaybackDuration] = songLength
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer?.currentTime ?? 0.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // Computed property for progress (0.0 to 1.0)
    var progress: Double {
        guard songLength > 0 else { return 0.0 }
        return currentTime / songLength
    }
    
    // Load songs from the Music folder in the app bundle
    public func loadSongsFromBundle(modelContext: ModelContext) -> [Song] {
        guard let musicPath = Bundle.main.resourcePath?.appending("/Music") else {
            print("Music folder not found")
            return []
        }
        
        var loadedSongs: [Song] = []
        
        do {
            let fileManager = FileManager.default
            let files = try fileManager.contentsOfDirectory(atPath: musicPath)
            let mp3Files = files.filter { $0.hasSuffix(".mp3") }
            
            for fileName in mp3Files {
                let songName = fileName.replacingOccurrences(of: ".mp3", with: "")
                let title = songName // Use filename as title
                
                // Check if song already exists
                let descriptor = FetchDescriptor<Song>(predicate: #Predicate { $0.songName == songName })
                let existingSongs = try? modelContext.fetch(descriptor)
                
                if let existing = existingSongs?.first {
                    loadedSongs.append(existing)
                } else {
                    let newSong = Song(title: title, songName: songName, artist: "Unknown Artist", locations: ["All"], populationMin: 0, populationMax: 10000000)
                    modelContext.insert(newSong)
                    loadedSongs.append(newSong)
                }
            }
            
            try? modelContext.save()
            print("Loaded \(mp3Files.count) songs from Music folder")
        } catch {
            print("Error loading songs: \(error)")
        }
        
        return loadedSongs
    }
    
    // MARK: Song File Locations
    // Directory where user-imported mp3s are stored (Documents/Music)
    static var importedMusicDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    // Resolve a song file by name: bundled Music folder first, then imported files
    static func url(forSongFile songName: String) -> URL? {
        if let path = Bundle.main.path(forResource: songName, ofType: "mp3", inDirectory: "Music") {
            return URL(fileURLWithPath: path)
        }
        let imported = importedMusicDirectory.appendingPathComponent("\(songName).mp3")
        return FileManager.default.fileExists(atPath: imported.path) ? imported : nil
    }

    // Import user-selected mp3 files: copy into Documents/Music, read ID3
    // title/artist when available, and insert new Song records.
    @MainActor
    public func importSongs(from urls: [URL], modelContext: ModelContext) async {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let songName = url.deletingPathExtension().lastPathComponent
            let destination = Self.importedMusicDirectory.appendingPathComponent("\(songName).mp3")

            // Copy the file in (even if a Song record already exists from a
            // previous failed attempt, the file may be missing)
            if !FileManager.default.fileExists(atPath: destination.path) || !songExists(songName, in: modelContext) {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Self.coordinatedCopy(from: url, to: destination)
                    }.value
                } catch {
                    print("Failed to copy imported song '\(songName)': \(error)")
                    continue
                }
            }

            // Skip the record insert for duplicates
            if songExists(songName, in: modelContext) {
                print("Song already exists, skipping record: \(songName)")
                continue
            }

            // Pull title/artist from ID3 tags, falling back to the filename
            var title = songName
            var artist = "Unknown Artist"
            let asset = AVURLAsset(url: destination)
            if let metadata = try? await asset.load(.commonMetadata) {
                if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first,
                   let value = try? await item.load(.stringValue) {
                    title = value
                }
                if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first,
                   let value = try? await item.load(.stringValue) {
                    artist = value
                }
            }

            let newSong = Song(title: title, songName: songName, artist: artist, locations: ["All"], populationMin: 0, populationMax: 10000000)
            modelContext.insert(newSong)
            print("Imported song: \(title)")
        }

        do {
            try modelContext.save()
        } catch {
            print("Failed to save imported songs: \(error)")
        }

        // Refresh the queue so new songs are playable immediately
        let allSongs = (try? modelContext.fetch(FetchDescriptor<Song>())) ?? []
        reloadQueue(newContext: currentContext, shuffle: isShuffled, songs: allSongs)
    }

    private func songExists(_ songName: String, in modelContext: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Song>(predicate: #Predicate { $0.songName == songName })
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    // File-coordinated copy. The .forUploading option materializes files that
    // aren't locally available yet (e.g. iCloud Drive items) before copying.
    private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?

        NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading, error: &coordinatorError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let error = coordinatorError { throw error }
        if let error = copyError { throw error }
    }

    // MARK: Audio Playback Functions
    // Play the music if not paused, pause the music if paused. ezpz
    public func musicPlayPause() {
        // If no audio is loaded and we have songs in queue, load the first one
        if audioPlayer == nil && !songQueue.isEmpty {
            currentSong = songQueue[currentIndex]
            loadAudio(fileName: songQueue[currentIndex].songName)
        }
        
        if audioPlayer != nil && audioPlayer!.isPlaying {
            audioPlayer!.pause()
            isPaused = true
            stopPlaybackTimer()
        }
        else if audioPlayer != nil && !audioPlayer!.isPlaying {
            audioPlayer!.play()
            isPaused = false
            startPlaybackTimer()
        }
        
        updateNowPlayingInfo()
        print("Audio Player is now \(isPaused ? "paused" : "playing")")
    }
    
    public func skip() {
        guard !songQueue.isEmpty else {
            print("No songs in queue")
            return
        }
        
        // Set the current index to the next song in the queue
        // if on the last song, loop back to the start of the queue
        currentIndex = (currentIndex + 1) % songQueue.count
        currentSong = songQueue[currentIndex]
        let nextSong = songQueue[currentIndex].songName
        
        loadAudio(fileName: nextSong)
        audioPlayer?.play()
        isPaused = false
        startPlaybackTimer()
        updateNowPlayingInfo()
    }
    
    // Jump to a specific song already in the queue and play it
    public func play(song: Song) {
        guard let index = songQueue.firstIndex(where: { $0.songName == song.songName }) else {
            print("Song not in queue: \(song.songName)")
            return
        }

        currentIndex = index
        currentSong = songQueue[currentIndex]
        loadAudio(fileName: songQueue[currentIndex].songName)
        audioPlayer?.play()
        isPaused = false
        startPlaybackTimer()
        updateNowPlayingInfo()
    }

    public func previous() {
        guard !songQueue.isEmpty else {
            print("No songs in queue")
            return
        }
        
        // Same as the skip function but in reverse
        currentIndex = (currentIndex - 1 + songQueue.count) % songQueue.count
        currentSong = songQueue[currentIndex]
        let previousSong = songQueue[currentIndex].songName
        
        loadAudio(fileName: previousSong)
        audioPlayer?.play()
        isPaused = false
        startPlaybackTimer()
        updateNowPlayingInfo()
    }

    // Toggle shuffle mode
    // Technically we can just call reloadQueue instead of this but it'll save an unnecessary full list reset
    // and slightly reduce lag if the user reshuffles
    public func toggleShuffle() {
        isShuffled.toggle()
        
        if(isShuffled) {
            songQueue.shuffle()
        } else {
            reloadQueue(newContext: currentContext, shuffle: isShuffled, songs: songQueue)
        }
    }

    // Prepare the audio player with the selected song
    private func loadAudio(fileName: String) {
        
        guard let url = Self.url(forSongFile: fileName) else {
            print("Could not find file: \(fileName).mp3")
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            songLength = audioPlayer?.duration ?? 0.0
            currentTime = 0.0
        } catch {
            print("Could not create audio player: \(error)")
        }
    }
    
    // MARK: AVAudioPlayerDelegate
    // Automatically play the next song when the current one finishes
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            print("Song finished, playing next song")
            skip()
        }
    }
    
    // MARK: Song Database Functions
    // Insert a new song
    // @TODO: Add field for uploading .mp3 files
    // @TODO: figure out how to handle the population detection issue
    public func addSong(title: String, artist: String, modelContext: ModelContext) {
        let newSong = Song(title: title, songName: "filename", artist: artist, locations: ["location"], populationMin: 0, populationMax: 9999)
        modelContext.insert(newSong)
        try? modelContext.save()
    }

    // Remove an existing song
    private func removeSong(_ song: Song, modelContext: ModelContext) {
        modelContext.delete(song)
        try? modelContext.save()
    }
    
    // Switch to a new context with a short crossfade.
    // Called when the user enters a new area (via ContextDetector).
    public func switchContext(to newContext: MusicContext, songs: [Song], fadeDuration: TimeInterval = 1.5) {
        guard newContext != currentContext else { return }

        currentContext = newContext
        let wasPlaying = audioPlayer?.isPlaying ?? false

        guard wasPlaying, let player = audioPlayer else {
            // Nothing audible — just swap the queue silently, no auto-play
            reloadQueue(newContext: newContext, shuffle: isShuffled, songs: songs)
            return
        }

        // Fade out the old song, then load the new queue and fade the next song in
        player.setVolume(0.0, fadeDuration: fadeDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration) { [weak self] in
            guard let self = self else { return }
            self.audioPlayer?.stop() // ensure the faded-out song doesn't keep playing if the new queue is empty
            self.reloadQueue(newContext: newContext, shuffle: self.isShuffled, songs: songs)

            guard let newPlayer = self.audioPlayer, self.currentSong != nil else { return }
            newPlayer.volume = 0.0
            newPlayer.play()
            newPlayer.setVolume(1.0, fadeDuration: fadeDuration)
            self.isPaused = false
            self.startPlaybackTimer()
            self.updateNowPlayingInfo()
        }
    }

    // Reset the queue upon entering a new location/context
    public func reloadQueue(newContext: MusicContext, shuffle: Bool, songs: [Song]) {
        
        songQueue.removeAll()
        
        // add only the new songs to the queue
        songQueue = songs.filter { $0.locations.contains(newContext.rawValue) }
        
        // shuffle if user has the option toggled
        if isShuffled {
            songQueue.shuffle()
        }
        
        // reset the current index to 0
        currentIndex = 0
        
        // Set the current song to the first in queue but don't auto-play
        if !songQueue.isEmpty {
            currentSong = songQueue[currentIndex]
            loadAudio(fileName: songQueue[currentIndex].songName)
            print("Queue loaded with \(songQueue.count) songs")
        } else {
            print("No songs matched the current context")
        }
    }
    
    // Timer management for playback progress
    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.currentTime = player.currentTime
            if !player.isPlaying {
                self.stopPlaybackTimer()
            }
        }
    }
    
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}
