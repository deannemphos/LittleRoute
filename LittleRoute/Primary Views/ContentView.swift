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
    
    @StateObject private var audioManager = AudioPlayerManager.shared
    @Environment(\.modelContext) private var modelContext
    
    @Query private var songs: [Song] // Query all songs from the database
    
    let sampleSong: Song = Song.init(title: "Sample Song", songName: "RSEmart", artist: "Sample Artist", locations: ["all"], populationMin: 0, populationMax: 10000 )
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
                        // Add song button
                        audioManager.addSong(title: "New Song", artist: "New Artist", modelContext: modelContext)
                        
                        // TEMP
                        print(songs)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .padding()
                }
                
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
                        audioManager.previous()
                        
                    } label: {
                        Image(systemName: "backward.fill") // @TODO -- implement previous song functionality
                            .imageScale(.large)
                    }
                    
                    // Play/Pause Button
                    Button {
                        
                        audioManager.currentSong == nil ? audioManager.currentSong = songs.first : () // Play the first song in the list if nothing is currently queued
                        
                        // TEMP FOR TESTING ONLY:
                        audioManager.currentSong == nil ? audioManager.currentSong = sampleSong : ()
                        // loadAudio(fileName: "RSEmart")
                        
                        audioManager.isPaused.toggle()
                        audioManager.musicPlayPause()
                    } label: {
                        Image(systemName: audioManager.isPaused ? "pause.fill" : "play.fill")
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
                    Text(audioManager.currentSong?.title ?? "No song playing")
                        .font(.title)
                        .padding()
                    Text(audioManager.currentSong?.artist ?? "No artist")
                    
                    Button {
                        audioManager.toggleShuffle()
                        
                    }
                    label: {
                        Image(systemName: audioManager.isShuffled ? "shuffle.circle.fill" : "shuffle.circle")
                    }
                }
            }
            // Set background color
            Color("Background").ignoresSafeArea(edges: .all)
                .zIndex(-1.0)
        }
        .onAppear {
            // Populate the song queue with all songs from the database
            audioManager.reloadQueue(newContext: audioManager.currentContext.rawValue, shuffle: audioManager.isShuffled, songs: songs)
        }
        .onChange(of: songs) {
            audioManager.reloadQueue(newContext: audioManager.currentContext.rawValue, shuffle: audioManager.isShuffled, songs: $0)
        }
    }
    
}
    
// MARK:
// MARK: - SwiftUI Preview -- does not work with SweetPad so it's getting disabled
/*
#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
*/
