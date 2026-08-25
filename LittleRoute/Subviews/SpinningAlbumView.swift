//
//  SpinningAlbumView.swift
//  LittleRoute
//
//  Circular album cover that spins like a CD while music plays.
//  Pulls artwork from the mp3's ID3 tags, falling back to a Y2K
//  holographic disc when no artwork is embedded.
//

import SwiftUI
import AVFoundation

struct SpinningAlbumView: View {
    @ObservedObject var audioManager: AudioPlayerManager

    let diameter: CGFloat

    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.y2k.rawValue
    private var theme: AppTheme { AppTheme.current(from: themeRaw) }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var artwork: UIImage? = nil

    // where the disc sits while parked, and the base angle the current run spins up from
    @State private var restAngle: Double = 0.0
    // flipping this inside a repeating animation is the whole spin — the render server
    // interpolates it, so nothing here re-evaluates per frame
    @State private var isSpinning = false
    // wall clock the current run started, so a pause can work out how far it actually got
    @State private var runStartedAt: Date?

    // one turn every 20 seconds. the old timer nudged 0.6° thirty times a second,
    // which is 18°/sec — same speed, one animation instead of 30 invalidations a second
    private let secondsPerRevolution = 20.0

    // only turn when there's actually something playing. reduce-motion folds in here too,
    // so those users just get a still disc and the pause bookkeeping below never runs
    private var shouldSpin: Bool {
        !reduceMotion && !audioManager.isPaused && audioManager.currentSong != nil
    }

    var body: some View {
        ZStack {
            // Album art (or holographic fallback disc)
            Group {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else if theme == .y2k {
                    // Iridescent CD look
                    AngularGradient(
                        colors: [Y2K.cyan, Y2K.pink, Y2K.lime, Y2K.purple, Y2K.cyan],
                        center: .center
                    )
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: diameter * 0.22, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    )
                } else {
                    // Flat minimal disc
                    Color(.secondarySystemBackground)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: diameter * 0.22, weight: .light))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())

            // CD groove rings + center hole
            Circle()
                .strokeBorder(theme == .y2k ? Color.white.opacity(0.25) : Color(.separator), lineWidth: diameter * 0.02)
                .frame(width: diameter * 0.55, height: diameter * 0.55)
            Circle()
                .fill(theme == .y2k ? AnyShapeStyle(Y2K.chromeGradient) : AnyShapeStyle(Color(.systemBackground)))
                .frame(width: diameter * 0.14, height: diameter * 0.14)
                .overlay(Circle().strokeBorder(theme == .y2k ? Color.white.opacity(0.7) : Color(.separator), lineWidth: 1.5))
        }
        .rotationEffect(.degrees(restAngle + (isSpinning ? 360.0 : 0.0)))
        // Rim (doesn't rotate)
        .overlay(
            Circle().strokeBorder(theme.rim, lineWidth: theme == .y2k ? 5 : 1)
        )
        .shadow(color: theme == .y2k ? Y2K.purple.opacity(0.5) : .clear, radius: 14)
        // The whole disc is ornament — groove rings, centre hole, rim, and the
        // music.note placeholder all read as raw symbol names, and the artwork
        // carries no information the curved title and artist above it don't
        // already speak. Take the lot out of the tree rather than labelling
        // scenery a VoiceOver user would have to swipe past every time.
        .accessibilityHidden(true)
        .onAppear {
            loadArtwork()
            if shouldSpin { startSpin() }
        }
        .onChange(of: shouldSpin) { _, spin in
            if spin { startSpin() } else { stopSpin() }
        }
        .onChange(of: scenePhase) { _, phase in
            // core animation drops repeating animations when the app suspends and doesn't
            // put them back, so park the disc on the way out and start a fresh run on return.
            // the old timer survived backgrounding on its own; this is what replaces that
            if phase == .active {
                if shouldSpin { startSpin() }
            } else {
                stopSpin()
            }
        }
        // keeps "runStartedAt != nil means an animation is live" true if the view is ever
        // torn down and rebuilt, which would otherwise leave the disc frozen
        .onDisappear { stopSpin() }
        .onChange(of: audioManager.currentSong) { _, _ in loadArtwork() }
    }

    private func startSpin() {
        guard runStartedAt == nil else { return } // already turning
        runStartedAt = .now
        withAnimation(.linear(duration: secondsPerRevolution).repeatForever(autoreverses: false)) {
            isSpinning = true
        }
    }

    private func stopSpin() {
        guard let startedAt = runStartedAt else { return } // already parked
        runStartedAt = nil

        // a record should pick up where it left off, so bank how far this run actually got
        // and land the disc there. without this the next run would snap back to zero
        let spun = Date.now.timeIntervalSince(startedAt) * (360.0 / secondsPerRevolution)
        withAnimation(nil) {
            restAngle = (restAngle + spun).truncatingRemainder(dividingBy: 360.0)
            isSpinning = false
        }
    }

    // Extract embedded artwork from the current song's mp3 (bundled or imported)
    private func loadArtwork() {
        guard let songName = audioManager.currentSong?.songName,
              let url = AudioPlayerManager.url(forSongFile: songName) else {
            artwork = nil
            return
        }

        let asset = AVURLAsset(url: url)
        Task {
            var image: UIImage? = nil
            if let metadata = try? await asset.load(.metadata) {
                let artworkItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
                if let item = artworkItems.first,
                   let data = try? await item.load(.dataValue) {
                    image = UIImage(data: data)
                }
            }
            await MainActor.run { artwork = image }
        }
    }
}
