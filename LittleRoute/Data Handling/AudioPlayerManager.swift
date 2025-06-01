//
//  AudioPlayerManager.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 5/7/25.
//

import Foundation
import AVFoundation
import SwiftUICore
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
    
    static let shared = AudioPlayerManager()
    
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
    }

    // MARK: Audio Playback Functions
    // Play the music if not paused, pause the music if paused. ezpz
    private func musicPlayPause() {
        if audioPlayer != nil && audioPlayer!.isPlaying {
            audioPlayer!.pause()
            isPaused.toggle()
        }
        else if audioPlayer != nil && !audioPlayer!.isPlaying {
            audioPlayer!.play()
            isPaused.toggle()
        }
    }
    
    private func skip() {
        // let nextSong = songs.first?.songName ?? "RSEmart"
        
        guard !songQueue.isEmpty else {
            print("No songs in queue")
            return
        }
        
        // Set the current index to the next song in the queue
        // if on the last song, loop back to the start of the queue
        let nextSong = songQueue[(currentIndex + 1) % songQueue.count].songName
        
        loadAudio(fileName: nextSong)
    }
    
    private func previous() {
        // let previousSong = songs.last?.songName ?? "RSEmart"
        
        guard !songQueue.isEmpty else {
            print("No songs in queue")
            return
        }
        
        // Same as the skip function but in reverse
        let previousSong = songQueue[(currentIndex - 1 + songQueue.count) % songQueue.count].songName
        
        loadAudio(fileName: previousSong)

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
            audioPlayer?.prepareToPlay()
            // songLength = audioPlayer?.duration ?? 0.0
        } catch {
            print("Could not create audio player: \(error)")
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
    
    // Reset the queue upon entering a new location/context
    private func reloadQueue(newContext: String, shuffle: Bool, songs: [Song]) {
        
        songQueue.removeAll()
        
        // add only the new songs to the queue
        songQueue = songs.filter { $0.locations.contains(newContext) }
        
        // shuffle if user has the option toggled
        if isShuffled {
            songQueue.shuffle()
        }
        
        // if the queue is empty, load the default song
        //loadAudio(fileName: songQueue.first?.songName ?? "RSEmart")
        
        // reset the current index to 0 and start playing
        if !songQueue.isEmpty {
            currentSong = songQueue[currentIndex]
            loadAudio(fileName: songQueue[currentIndex].songName)
            audioPlayer?.play()
            isPaused = false
        }
        
    }
    
    // Toggle shuffle mode
    // Technically we can just call reloadQueue instead of this but it'll save an unnecessary full list reset
    // and slightly reduce lag if the user reshuffles
    private func toggleShuffle() {
        isShuffled.toggle()
        
        if(isShuffled) {
            songQueue.shuffle()
        } else {
            reloadQueue(newContext: currentContext.rawValue, shuffle: isShuffled, songs: songQueue)
        }
    }
}
