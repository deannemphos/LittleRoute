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
import UniformTypeIdentifiers


struct ContentView: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    @Environment(\.modelContext) private var modelContext

    // Owned by LittleRouteApp and injected, not constructed here: a View can't
    // own these. Re-initializing ContentView would have built a second
    // CLLocationManager and reset the detector's dwell/debt/buffer state.
    @EnvironmentObject private var locationHandler: LocationHandler
    @EnvironmentObject private var contextDetector: ContextDetector

    @Query private var songs: [Song] // Query all songs from the database
    @State private var queueDrawerOpen = false
    @State private var showLibrary = false
    @State private var showFileImporter = false
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.minimal.rawValue
    private var theme: AppTheme { AppTheme.current(from: themeRaw) }

    let c_radius: CGFloat = 20.0 // corner radius for consistency

    // Sizing for the disc + map stack
    private let albumDiameter: CGFloat = 320.0
    private let mapDiameter: CGFloat = 260.0

    var body: some View {

        // Show error screen if location permission is denied
        if locationHandler.authorizationStatus == .denied || locationHandler.authorizationStatus == .restricted {
            ErrorView(
                errorTitle: "Location Access Required",
                errorMessage: "LittleRoute needs your location to play music matching your surroundings.",
                fixInstructions: "Go to Settings > Privacy & Security > Location Services and enable location for LittleRoute.",
                onRetryAction: { locationHandler.requestLocationAuthorization() }
            )
        } else {

        ZStack {
            Color.clear
                .background(theme.background)
            
                // film grain shader over the background; disabled until I figure out the art style
                // .filmGrain(intensity: theme.grainIntensity)
                .ignoresSafeArea()

            VStack(spacing: 0) {

                // Wordmark
                Text("LittleRoute")
                    .font(.system(size: 38, weight: theme == .y2k ? .black : .semibold, design: theme == .y2k ? .rounded : .default))
                    .foregroundStyle(theme.titleStyle)
                    .shadow(color: theme == .y2k ? .white.opacity(0.9) : .clear, radius: 0, y: 1)
                    .shadow(color: theme.titleGlow, radius: 6, y: 3)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                
                // Spinny circle tinted to the active context
                ContextRingView(context: audioManager.currentContext, diameter: 24, color: audioManager.currentContext.tintColor)

                Text(theme == .y2k ? "✧ \(audioManager.currentContext.rawValue) ✧" : audioManager.currentContext.rawValue)
                    .font(.system(size: 15, weight: theme == .y2k ? .bold : .regular, design: theme == .y2k ? .rounded : .default))
                    .foregroundStyle(theme.secondaryText)
                    .shadow(color: theme.titleGlow, radius: 2, y: 1)
                    .padding(.top, 2)
                    // the y2k sparkles are read out as "white four pointed star" twice,
                    // and a bare "Gyms" doesn't say what it is. Say both.
                    .accessibilityLabel("Current context, \(audioManager.currentContext.rawValue)")

                Spacer()

                // Spinning album disc with the circular map on top,
                // song title + artist curving around the top of the disc
                ZStack {

                    // SpinningAlbumView(audioManager: audioManager, locationHandler: locationHandler, diameter: albumDiameter)
                    SpinningAlbumView(audioManager: audioManager, diameter: albumDiameter)

                    MapView(
                        contextDetector: contextDetector,
                        context: audioManager.currentContext
                    )
                        .frame(width: mapDiameter, height: mapDiameter)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(theme.rim, lineWidth: theme.rimWidth))
                        .shadow(color: theme.shadowColor, radius: 8)

                    // Curved song title (outer arc) and artist (inner arc).
                    // The two arcs are visually distinguished by radius alone, which
                    // tells a VoiceOver user nothing — hence the spoken prefixes.
                    CurvedText(
                        text: audioManager.currentSong?.title ?? "No song playing",
                        radius: albumDiameter / 2 + 18,
                        fontSize: 14,
                        color: theme.primaryText,
                        spokenLabel: "Now playing, \(audioManager.currentSong?.title ?? "no song")"
                    )
                    CurvedText(
                        text: audioManager.currentSong?.artist ?? "Unknown Artist",
                        radius: albumDiameter / 2 + 8,
                        fontSize: 12,
                        color: theme.secondaryText,
                        spokenLabel: "Artist, \(audioManager.currentSong?.artist ?? "unknown")"
                    )
                }
                .padding(.top, 30) // room for the curved text arcs

                // Song progress bar
                ProgressView(value: audioManager.progress)
                    .tint(theme.accent)
                    .background(Capsule().fill(theme == .y2k ? Color.white.opacity(0.5) : Color(.systemGray5)))
                    .frame(width: albumDiameter * 0.8)
                    .padding(.top, 20)
                    // otherwise it announces a bare percentage with no idea what of
                    .accessibilityLabel("Playback progress")

                // Playback controls: back, play/pause, skip
                HStack(spacing: 28) {
                    Button {
                        audioManager.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(ThemedRoundButtonStyle(theme: theme, size: 60, tint: Y2K.purple))
                    .accessibilityLabel("Previous song")

                    Button {
                        audioManager.musicPlayPause()
                    } label: {
                        Image(systemName: audioManager.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(ThemedRoundButtonStyle(theme: theme, size: 80, tint: Y2K.pink))
                    // one button, two jobs — the label has to track the glyph or it
                    // will offer to play something that's already playing
                    .accessibilityLabel(audioManager.isPaused ? "Play" : "Pause")

                    Button {
                        audioManager.skip()
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(ThemedRoundButtonStyle(theme: theme, size: 60, tint: Y2K.purple))
                    .accessibilityLabel("Next song")
                }
                .padding(.top, 16)

                // Shuffle + manual context refresh
                HStack(spacing: 16) {
                    Button {
                        audioManager.toggleShuffle()
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(ThemedPillButtonStyle(theme: theme, tint: Y2K.cyan, isActive: audioManager.isShuffled))
                    // the Label already names it; what's missing is that it's a toggle
                    // whose on-state is signalled purely by fill colour
                    .accessibilityValue(audioManager.isShuffled ? "On" : "Off")

                    Button {
                        contextDetector.refreshNow()
                    } label: {
                        Label("Update Context", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(ThemedPillButtonStyle(theme: theme, tint: Y2K.lime))
                    .accessibilityHint("Rechecks your surroundings and picks music to match.")
                }
                .padding(.top, 18)

                Spacer()
            }

            // Swipeable song queue drawer pinned to the left edge
            QueueDrawerView(audioManager: audioManager, isOpen: $queueDrawerOpen)

            // Theme switcher
            VStack {
                HStack {
                    // Music library: import MP3s and tag songs with contexts
                    Button {
                        showLibrary = true
                    } label: {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.secondaryText)
                            .padding(10)
                    }
                    .accessibilityLabel("Music library")
                    // Quick-import MP3s from the Files app
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.secondaryText)
                            .padding(10)
                    }
                    .accessibilityLabel("Import songs")
                    .accessibilityHint("Choose MP3s from the Files app.")
                    Spacer()
                    Button {
                        themeRaw = theme.next.rawValue
                    } label: {
                        Image(systemName: "paintbrush.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.secondaryText)
                            .padding(10)
                    }
                    // which theme is on is otherwise a purely visual fact, and the
                    // button cycles rather than opening a picker — say where it lands
                    .accessibilityLabel("Change theme")
                    .accessibilityValue(theme.rawValue)
                    .accessibilityHint("Switches to the \(theme.next.rawValue) theme.")
                }
                Spacer()
            }
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.mp3],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await audioManager.importSongs(from: urls, modelContext: modelContext)
                }
            case .failure(let error):
                print("File import failed: \(error)")
            }
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

            // Switch music automatically when the user dwells in a new area
            contextDetector.onContextChange = { newContext in
                audioManager.switchContext(to: newContext, songs: songs)
            }
            contextDetector.start()
            audioManager.musicPlayPause() // Auto-start playback on launch if songs are available
        }
        .onChange(of: songs) { oldValue, newValue in
            audioManager.reloadQueue(newContext: audioManager.currentContext, shuffle: audioManager.isShuffled, songs: newValue)
            // Re-capture the latest song list for future context switches
            contextDetector.onContextChange = { newContext in
                audioManager.switchContext(to: newContext, songs: newValue)
            }
        }
        } // end else (location permission granted)
    }

}
