//
//  ContentView.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 12/4/24.
//

import SwiftUI
import SwiftData
import MapKit
import AVFoundation

struct ContentView: View {

    @Environment(\.modelContext) private var modelContext

    @Query private var songs: [Song] // Query all songs from the database

    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPaused: Bool = false
    @State private var isShuffled: Bool = false
    @State private var songLength: TimeInterval = 0.0   // total length of the song
    @State private var currentTime: TimeInterval = 0.0  // current playback time

    @State private var currentContext: Context = .all
    @State private var currentSong: Song? = nil // the currently playing song, if any
    @State private var songQueue: [Song] = []
   
    let sampleSong: Song = Song.init(title: "Sample Song", songName: "RSEmart", artist: "Sample Artist", locations: ["all"], populationMin: 0, populationMax: 10000 )
    let c_radius: CGFloat = 20.0 // corner radius for consistency
    
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

    var body: some View {

        ZStack {
            VStack {
                
                // Map!
                Map() {
                    
                }
                .frame(width: 300, height: 300)
                .cornerRadius(c_radius)
                .padding()
                
                // Location info
                LazyVStack {
                    
                }
                .background(.black)
                .padding()
                .cornerRadius(c_radius)
                
                // Music bar
                HStack {

                    // Previous Button
                    Button {
                        loadAudio(fileName: "RSEmart")
                        
                    } label: {
                        Image(systemName: "backward.fill") // @TODO -- implement previous song functionality
                            .imageScale(.large)
                    }
                    
                    // Play/Pause Button
                    Button {
                        
                        currentSong == nil ? currentSong = songs.first : () // Play the first song in the list if nothing is currently queued
                        
                        // TEMP FOR TESTING ONLY:
                        currentSong == nil ? currentSong = sampleSong : ()
                        // loadAudio(fileName: "RSEmart")
                        
                        isPaused.toggle()
                        musicPlayPause()
                    } label: {
                        Image(systemName: isPaused ? "pause.fill" : "play.fill")
                            .imageScale(.large)
                    }
                    ProgressView(value: /*@START_MENU_TOKEN@*/0.5/*@END_MENU_TOKEN@*/) // @TODO -- Show song's current progression
                }
                .padding()
                
                // Skip Button
                Button {
                    // loadAudio(fileName: songs) // @TODO -- add in skip functionality
                } label: {
                    Image(systemName: "forward.fill")
                        .imageScale(.large)
                }

                VStack {
                    Text(currentSong?.title ?? "No song playing")
                        .font(.title)
                        .padding()
                    Text(currentSong?.artist ?? "No artist")
                    
                    Button {
                        isShuffled.toggle()
                        
                    }
                    label: {
                        Image(systemName: isShuffled ? "shuffle.circle.fill" : "shuffle.circle")
                    }
                }
            }
            // Set background color
            Color("Background").ignoresSafeArea(edges: .all)
                .zIndex(-1.0)
        }
    }
    
    
    // MARK: Audio Functions
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
        
        // find next song in queue
        let nextSong = songs.first?.songName ?? "RSEmart"
        
        // load audio for song
        loadAudio(fileName: nextSong)
    }
    
    private func previous() {
        
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
    private func addSong(title: String, artist: String, modelContext: ModelContext) {
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
    private func reloadQueue(newContext: String, shuffle: Bool) {
        
        songQueue.removeAll()
        
        // add only the new songs to the queue
        songQueue = songs.filter { $0.locations.contains(newContext) }
        
        // shuffle if user has the option toggled
        if isShuffled {
            songQueue.shuffle()
        }
        
        // @TODO: change the default song from RSEmart to something else
        loadAudio(fileName: songQueue.first?.songName ?? "RSEmart")
        
    }
    
    // Toggle shuffle mode
    // Technically we can just call reloadQueue instead of this but it'll save an unnecessary full list reset
    // and slightly reduce lag if the user reshuffles
    private func toggleShuffle() {
        isShuffled.toggle()
        
        if(isShuffled) {
            songQueue.shuffle()
        } else {
            reloadQueue(newContext: currentContext.rawValue, shuffle: isShuffled)
        }
    }
}

// MARK: - SwiftUI Preview -- does not work with SweetPad so it's getting disabled
/*
#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
*/
