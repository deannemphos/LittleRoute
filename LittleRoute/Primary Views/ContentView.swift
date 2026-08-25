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

    // The same probe CurvedText uses on itself. This screen has to know how big
    // the arc text is going to be *before* it can decide how big the disc can
    // be, so it reads the text setting through the identical clamp rather than
    // guessing — see CurvedText.Metrics.
    @ScaledMetric(relativeTo: .caption) private var arcScaleProbe: CGFloat = CurvedText.Metrics.probeBase

    let c_radius: CGFloat = 20.0 // corner radius for consistency

    // MARK: - Layout
    //
    // The disc used to be a hardcoded 320pt with the title arc pinned 18pt
    // outside it. A glyph is centred *on* its arc, so that layout wants about
    // 376pt of width — wider than an iPhone SE's entire screen, and the title
    // ran off both edges before Dynamic Type was even in the picture. Everything
    // below is now a share of what the container actually offers, capped at the
    // old numbers so nothing changes on a phone that was already big enough.
    private enum Layout {
        static let maxAlbumDiameter: CGFloat = 320.0   // what it always was
        static let minAlbumDiameter: CGFloat = 150.0   // never collapse to a dot
        static let mapShare: CGFloat = 0.8125          // the old 260 / 320
        static let progressShare: CGFloat = 0.8
        // the disc gets at most this much of the column's height, so the
        // transport controls below it stay put on a short screen
        static let heightShare: CGFloat = 0.42
        static let screenMargin: CGFloat = 8.0
        static let titleArcInset: CGFloat = 18.0       // gap from disc rim to title arc
        static let artistArcInset: CGFloat = 8.0
        static let titleArcFontSize: CGFloat = 14.0
        static let artistArcFontSize: CGFloat = 12.0
        static let arcHeadroom: CGFloat = 30.0         // old fixed top padding
    }

    private var arcScale: CGFloat { CurvedText.Metrics.scale(fromProbe: arcScaleProbe) }
    private var titleArcInset: CGFloat { Layout.titleArcInset * arcScale }
    private var artistArcInset: CGFloat { Layout.artistArcInset * arcScale }

    // How far past the disc's own edge the title arc actually paints: the gap
    // out to the arc, plus the half of each glyph that hangs outside it.
    private var arcReach: CGFloat {
        titleArcInset + CurvedText.Metrics.glyphOverhang(fontSize: Layout.titleArcFontSize * arcScale)
    }

    private func albumDiameter(in size: CGSize) -> CGFloat {
        let byWidth = size.width - 2.0 * (Layout.screenMargin + arcReach)
        let byHeight = size.height * Layout.heightShare
        return max(Layout.minAlbumDiameter, min(Layout.maxAlbumDiameter, min(byWidth, byHeight)))
    }

    // MARK: - Body

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
            player
        }
    }

    // Pulled out of `body` because the whole screen used to be one expression:
    // a single ZStack of ternaries that the type checker was already slow on,
    // and this change adds a GeometryReader on top of it. Splitting it into
    // named pieces costs nothing at runtime and keeps each one small enough to
    // infer quickly.
    private var player: some View {
        ZStack {
            Color.clear
                .background(theme.background)

                // film grain shader over the background; disabled until I figure out the art style
                // .filmGrain(intensity: theme.grainIntensity)
                .ignoresSafeArea()

            // the disc, the map and the arcs all size off the space this hands
            // back, which is the safe area rather than the whole screen
            GeometryReader { proxy in
                playerColumn(in: proxy.size)
            }

            // Swipeable song queue drawer pinned to the left edge
            QueueDrawerView(audioManager: audioManager, isOpen: $queueDrawerOpen)

            // Theme switcher
            topBar
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

            // Started *before* the queue is built, which is the whole of LR-13's
            // half of this. start() is where the detector rehydrates the context
            // it was last confirmed in, so asking it afterwards is the only way
            // the answer can be anything but its initial value.
            contextDetector.start()

            // ...and this is that answer being handed over. The reloadQueue
            // calls below read currentContext, and the onChange further down
            // deliberately never fires for an initial value — so without this
            // line a restored .beach would sit in the detector, unheard, until
            // the next confirmed switch, with the header still reading "All"
            // over a beach playlist.
            //
            // Assigned rather than routed through switchContext because
            // switchContext no-ops when the two already agree, and that is the
            // ordinary cold start — the one launch that most needs its queue
            // built. There is nothing audible to cross-fade from yet either;
            // playback starts at the bottom of this closure.
            audioManager.currentContext = contextDetector.confirmedContext

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

            // Auto-start playback on launch, unless the user is already listening
            // to something else — see startPlaybackIfNothingElseIsPlaying
            audioManager.startPlaybackIfNothingElseIsPlaying()
        }
        .onChange(of: songs) { oldValue, newValue in
            audioManager.reloadQueue(newContext: audioManager.currentContext, shuffle: audioManager.isShuffled, songs: newValue)
        }
        // Switch music automatically when the user dwells in a new area.
        //
        // This used to be a closure handed to the detector in onAppear, which
        // captured `songs` and therefore went stale the instant anything was
        // imported — so the onChange above had to re-assign it by hand, and the
        // app was one forgotten line away from picking a new context's music
        // out of a song list that predated the user's library. Reading `songs`
        // here instead means it is whatever SwiftUI last handed this view, as
        // of the moment the context actually changed. Nothing to keep in sync.
        //
        // onChange won't fire for the value the detector starts on; the
        // currentContext assignment in onAppear is who covers launch. A restore
        // *does* land as a change here — start() publishes it — but by then
        // onAppear has already made currentContext agree, so this arrives as
        // the no-op switchContext guards against rather than as a crossfade
        // into music that is already playing. That guard is also why standing
        // still can't trigger one.
        .onChange(of: contextDetector.confirmedContext) { _, newContext in
            audioManager.switchContext(to: newContext, songs: songs)
        }
    }

    // MARK: - Player column

    private func playerColumn(in size: CGSize) -> some View {
        let diameter = albumDiameter(in: size)

        return ScrollView {
            VStack(spacing: 0) {
                header

                Spacer()

                // Spinning album disc with the circular map on top,
                // song title + artist curving around the top of the disc
                discStack(diameter: diameter)
                    // room for the curved text arcs — which now grow with the
                    // text setting, so the gap above them has to as well
                    .padding(.top, max(Layout.arcHeadroom, arcReach))

                progressBar(width: diameter * Layout.progressShare)
                playbackControls
                secondaryControls

                Spacer()
            }
            // two frames because there is no overload taking a fixed width and a
            // minimum height together. minHeight keeps the Spacers doing exactly
            // what they always did at ordinary text sizes — the column still
            // fills and centres the same way — while letting it grow taller than
            // the screen and scroll at accessibility sizes, instead of shoving
            // the transport controls off the bottom
            .frame(width: size.width)
            .frame(minHeight: size.height)
        }
        // so there's no rubber-band on a screen where nothing needed to scroll
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        VStack(spacing: 0) {
            // Wordmark
            Text("LittleRoute")
                .themedFont(.wordmark, theme: theme)
                // it's branding and a single unbreakable word: at the top
                // accessibility sizes it can't fit an SE on one line and won't
                // wrap, so let it shrink rather than truncate to "LittleRou…"
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(theme.titleStyle)
                .shadow(color: theme == .y2k ? .white.opacity(0.9) : .clear, radius: 0, y: 1)
                .shadow(color: theme.titleGlow, radius: 6, y: 3)
                .padding(.top, 8)
                .padding(.horizontal, Layout.screenMargin)
                .accessibilityAddTraits(.isHeader)

            // Spinny circle tinted to the active context
            ContextRingView(context: audioManager.currentContext, diameter: 24, color: audioManager.currentContext.tintColor)

            Text(theme == .y2k ? "✧ \(audioManager.currentContext.rawValue) ✧" : audioManager.currentContext.rawValue)
                .themedFont(.contextLabel, theme: theme)
                .foregroundStyle(theme.secondaryText)
                .shadow(color: theme.titleGlow, radius: 2, y: 1)
                // context names get long ("Restaurant") and this one is allowed
                // to wrap, unlike the wordmark — it's information, not a logo
                .multilineTextAlignment(.center)
                .padding(.top, 2)
                .padding(.horizontal, Layout.screenMargin)
                // the y2k sparkles are read out as "white four pointed star" twice,
                // and a bare "Gyms" doesn't say what it is. Say both.
                .accessibilityLabel("Current context, \(audioManager.currentContext.rawValue)")
        }
    }

    private func discStack(diameter: CGFloat) -> some View {
        ZStack {

            // SpinningAlbumView(audioManager: audioManager, locationHandler: locationHandler, diameter: albumDiameter)
            SpinningAlbumView(audioManager: audioManager, diameter: diameter)

            MapView(
                contextDetector: contextDetector,
                context: audioManager.currentContext
            )
                .frame(width: diameter * Layout.mapShare, height: diameter * Layout.mapShare)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(theme.rim, lineWidth: theme.rimWidth))
                .shadow(color: theme.shadowColor, radius: 8)

            // Curved song title (outer arc) and artist (inner arc).
            // The two arcs are visually distinguished by radius alone, which
            // tells a VoiceOver user nothing — hence the spoken prefixes.
            CurvedText(
                text: audioManager.currentSong?.title ?? "No song playing",
                radius: diameter / 2.0 + titleArcInset,
                fontSize: Layout.titleArcFontSize,
                color: theme.primaryText,
                spokenLabel: "Now playing, \(audioManager.currentSong?.title ?? "no song")"
            )
            CurvedText(
                text: audioManager.currentSong?.artist ?? "Unknown Artist",
                radius: diameter / 2.0 + artistArcInset,
                fontSize: Layout.artistArcFontSize,
                color: theme.secondaryText,
                spokenLabel: "Artist, \(audioManager.currentSong?.artist ?? "unknown")"
            )
        }
    }

    // Song progress bar
    private func progressBar(width: CGFloat) -> some View {
        ProgressView(value: audioManager.progress)
            .tint(theme.accent)
            .background(Capsule().fill(theme == .y2k ? Color.white.opacity(0.5) : Color(.systemGray5)))
            .frame(width: width)
            .padding(.top, 20)
            // otherwise it announces a bare percentage with no idea what of
            .accessibilityLabel("Playback progress")
    }

    // MARK: - Controls

    // Playback controls: back, play/pause, skip.
    // Fixed sizes on purpose — these are hit targets, not text, and 60/80pt is
    // already well past the 44pt minimum at every text size.
    private var playbackControls: some View {
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
    }

    // Shuffle + manual context refresh.
    // These two carry text, so at accessibility sizes the pair stops fitting
    // side by side. Let them stack rather than run off both edges.
    private var secondaryControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                shuffleButton
                refreshContextButton
            }
            VStack(spacing: 10) {
                shuffleButton
                refreshContextButton
            }
        }
        .padding(.top, 18)
    }

    private var shuffleButton: some View {
        Button {
            audioManager.toggleShuffle()
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        .buttonStyle(ThemedPillButtonStyle(theme: theme, tint: Y2K.cyan, isActive: audioManager.isShuffled))
        // the Label already names it; what's missing is that it's a toggle
        // whose on-state is signalled purely by fill colour
        .accessibilityValue(audioManager.isShuffled ? "On" : "Off")
    }

    private var refreshContextButton: some View {
        Button {
            contextDetector.refreshNow()
        } label: {
            Label("Update Context", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(ThemedPillButtonStyle(theme: theme, tint: Y2K.lime))
        .accessibilityHint("Rechecks your surroundings and picks music to match.")
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack {
            HStack {
                // Music library: import MP3s and tag songs with contexts
                Button {
                    showLibrary = true
                } label: {
                    Image(systemName: "music.note.list")
                        .themedFont(.controlGlyph, theme: theme)
                        .foregroundStyle(theme.secondaryText)
                        .padding(10)
                }
                .accessibilityLabel("Music library")
                // Quick-import MP3s from the Files app
                Button {
                    showFileImporter = true
                } label: {
                    Image(systemName: "plus.circle")
                        .themedFont(.controlGlyph, theme: theme)
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
                        .themedFont(.controlGlyph, theme: theme)
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

}
