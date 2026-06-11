//
//  AudioPlayerManager.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 5/7/25.
//

import Foundation
import AVFoundation
import SwiftUI
import _SwiftData_SwiftUI

class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    @Published var isPaused: Bool = false
    @Published var isShuffled: Bool = false
    @Published var songLength: TimeInterval = 0.0   // total length of the song
    @Published var currentTime: TimeInterval = 0.0  // current playback time
    @Published var currentContext: Context = .all
    @Published var currentSong: Song? = nil // the currently playing song, if any

    private var audioPlayer: AVAudioPlayer?
    private var currentIndex: Int = 0 // index of the current song in the queue
    private var songQueue: [Song] = []
    private var playbackTimer: Timer?
    
    static let shared = AudioPlayerManager()
    
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
    
    // all contexts the music will account for
    enum Context: String {
        case all = "All"
        case gym = "Gyms"
        case restaurant = "Restaurants"
        case store = "Stores"
        case park = "Parks"
        case home = "Home"
        case work = "Work"
        case street = "Streets"
        case driving = "Driving"
        case beach = "Beaches"
        case mountain = "Mountains"
        case city = "Cities"
        case town = "Towns"
        case water = "Water"
        case traveling = "Traveling" // fallback when no recognizable POI is nearby
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
        
        guard let path = Bundle.main.path(forResource: fileName, ofType: "mp3", inDirectory: "Music") else {
            print("Could not find file: \(fileName).mp3")
            return
        }
        
        let url = URL(fileURLWithPath: path)
        
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
    public func switchContext(to newContext: Context, songs: [Song], fadeDuration: TimeInterval = 1.5) {
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
        }
    }

    // Reset the queue upon entering a new location/context
    public func reloadQueue(newContext: Context, shuffle: Bool, songs: [Song]) {
        
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
