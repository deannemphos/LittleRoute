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

    @State private var rotation: Double = 0.0
    @State private var artwork: UIImage? = nil

    private let spinTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

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
        .rotationEffect(.degrees(rotation))
        // Rim (doesn't rotate)
        .overlay(
            Circle().strokeBorder(theme.rim, lineWidth: theme == .y2k ? 5 : 1)
        )
        .shadow(color: theme == .y2k ? Y2K.purple.opacity(0.5) : .clear, radius: 14)
        .onReceive(spinTimer) { _ in
            guard !audioManager.isPaused, audioManager.currentSong != nil else { return }
            rotation = (rotation + 0.6).truncatingRemainder(dividingBy: 360.0)
        }
        .onAppear { loadArtwork() }
        .onChange(of: audioManager.currentSong) { _, _ in loadArtwork() }
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
