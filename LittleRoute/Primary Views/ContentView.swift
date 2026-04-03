// Swift
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
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    @Environment(\.modelContext) private var modelContext
    
    @StateObject private var locationHandler = LocationHandler()

    @Query private var songs: [Song] // Query all songs from the database
    @State private var showSongList = false
    
    let sampleSong: Song = Song(title: "Sample Song", songName: "RSEmart", artist: "Sample Artist", locations: ["all"], populationMin: 0, populationMax: 10000)
    let c_radius: CGFloat = 20.0 // corner radius for consistency
    
    var body: some View {
        
        ZStack {
            VStack {
                
                // Top bar
                HStack {
                    Button {
                        // Settings button
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .padding()
                    
                    Spacer()
                    Text("LittleRoute")
                        .font(.largeTitle)
                        .padding()
                    Spacer()
                    Button {
                        // Show song list
                        showSongList.toggle()
                    } label: {
                        Image(systemName: "music.note.list")
                    }
                    .padding()
                }
                
                // Map!
                Map() {
                    
                }
                .frame(width: 300, height: 300)
                .cornerRadius(c_radius)
                .padding()
                
                // Song list
                if showSongList {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(songs, id: \.songName) { song in
                                Button {
                                    audioManager.currentSong = song
                                    audioManager.reloadQueue(newContext: audioManager.currentContext, shuffle: audioManager.isShuffled, songs: songs)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(song.title)
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            Text(song.artist ?? "Unknown Artist")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if audioManager.currentSong?.songName == song.songName {
                                            Image(systemName: "speaker.wave.2.fill")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    .padding()
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(8)
                                }
                            }
                        }
                        .padding()
                    }
                    .frame(height: 200)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(c_radius)
                    .padding(.horizontal)
                }
                
                // Music bar
                HStack {
                    
                    // Previous Button
                    Button {
                        audioManager.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .imageScale(.large)
                    }
                    
                    // Play/Pause Button
                    Button {

                        audioManager.musicPlayPause()
                    } label: {
                        Image(systemName: audioManager.isPaused ? "play.fill" : "pause.fill")
                            .imageScale(.large)
                    }
                    // Song progress bar
                    ProgressView(value: audioManager.progress)
                }
                .padding()
                
                // Skip Button
                Button {
                    audioManager.skip()
                } label: {
                    Image(systemName: "forward.fill")
                        .imageScale(.large)
                }
                
                VStack {
                    Text(audioManager.currentSong?.title ?? "No song playing")
                        .font(.title)
                        .padding()
                    Text(audioManager.currentSong?.artist ?? "No artist")
                    
                    Button {
                        audioManager.toggleShuffle()
                    } label: {
                        Image(systemName: audioManager.isShuffled ? "shuffle.circle.fill" : "shuffle.circle")
                    }
                }
            }
            // Set background color
            Color("Background").ignoresSafeArea(edges: .all)
                .zIndex(-1.0)
        }
        .onAppear {
            locationHandler.requestLocationAuthorization()
            locationHandler.startLocationUpdates()
            // Load songs from Music folder if none exist
            if songs.isEmpty {
                let loadedSongs = audioManager.loadSongsFromBundle(modelContext: modelContext)
                // Queue the loaded songs immediately
                if !loadedSongs.isEmpty {
                    audioManager.reloadQueue(newContext: audioManager.currentContext, shuffle: audioManager.isShuffled, songs: loadedSongs)
                }
            } else {
                // Populate the song queue with all songs from the database
                audioManager.reloadQueue(newContext: audioManager.currentContext, shuffle: audioManager.isShuffled, songs: songs)
            }
        }
        .onChange(of: songs) { oldValue, newValue in
            audioManager.reloadQueue(newContext: audioManager.currentContext, shuffle: audioManager.isShuffled, songs: newValue)
        }
    }
    
}
