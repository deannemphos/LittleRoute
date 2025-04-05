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
    @State private var paused: Bool = false
    @State private var songLength: TimeInterval = 0.0   // total length of the song
    @State private var currentTime: TimeInterval = 0.0  // current playback time

    @State private var currentSong: Song? = nil // the currently playing song, if any
   
    let sampleSong: Song = Song.init(title: "Sample Song", songName: "RSEmart", artist: "Sample Artist", locations: ["all"], populationMin: 0, populationMax: 10000 )
    let c_radius: CGFloat = 20.0 // corner radius for consistency
    

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


                    Button {
                        
                        currentSong == nil ? currentSong = songs.first : () // Play the first song in the list if nothing is currently queued
                        
                        // TEMP FOR TESTING ONLY:
                        currentSong == nil ? currentSong = sampleSong : ()
                        loadAudio(fileName: "RSEmart")
                        
                        paused = !paused
                        musicPlayPause()
                    } label: {
                        Image(systemName: paused ? "pause.fill" : "play.fill")
                            .imageScale(.large)
                    }
                    ProgressView(value: /*@START_MENU_TOKEN@*/0.5/*@END_MENU_TOKEN@*/) // @TODO -- Show song's current progression
                }
                .padding()

                VStack {
                    Text(currentSong?.title ?? "No song playing")
                        .font(.title)
                        .padding()
                    Text(currentSong?.artist ?? "No artist")
                }
            }
            // Set background color
            Color("Background").ignoresSafeArea(edges: .all)
                .zIndex(-1.0)
        }
    }
    
    // Play the music if not paused, pause the music if paused. ezpz
    private func musicPlayPause() {
        if audioPlayer != nil && audioPlayer!.isPlaying {
            audioPlayer!.pause()
            paused = !paused
        }
        else if audioPlayer != nil && !audioPlayer!.isPlaying {
            audioPlayer!.play()
            paused = !paused
        }
    }
    
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
    
    // Get current
    
}

// MARK: - SwiftUI Preview -- does not work with SweetPad so it's getting disabled
/*
#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
*/
