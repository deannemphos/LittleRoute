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
import ImageIO
import SwiftData
import UIKit
import os

struct SpinningAlbumView: View {
    // Plain reference, no wrapper: this view reads isPaused and currentSong, and
    // with @Observable those two reads are the whole of its dependency on the
    // manager. That matters more here than anywhere else -- the disc is the view
    // the progress timer used to invalidate twice a second for nothing, which is
    // the same invalidation the spin animation below was written to avoid.
    let audioManager: AudioPlayerManager

    let diameter: CGFloat

    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.y2k.rawValue
    private var theme: AppTheme { AppTheme.current(from: themeRaw) }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var artwork: LoadedArtwork?
    @State private var isVisible = false

    private struct ArtworkRequest: Equatable {
        let songID: PersistentIdentifier
        let fileName: String
        let isImported: Bool
        let maxPixelSize: Int
    }

    private struct LoadedArtwork {
        let request: ArtworkRequest
        let image: UIImage
    }

    private var artworkRequest: ArtworkRequest? {
        guard let song = audioManager.currentSong,
              diameter.isFinite, displayScale.isFinite,
              diameter > 0, displayScale > 0 else { return nil }
        return ArtworkRequest(
            songID: song.persistentModelID,
            fileName: song.songName,
            isImported: song.isImported,
            maxPixelSize: Int(min(4096, (diameter * displayScale).rounded(.up)))
        )
    }

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
        isVisible && scenePhase == .active && !reduceMotion
            && !audioManager.isPaused && audioManager.currentSong != nil
    }

    var body: some View {
        let request = artworkRequest
        ZStack {
            // Album art (or holographic fallback disc)
            Group {
                if let artwork, artwork.request == request {
                    Image(uiImage: artwork.image)
                        .resizable()
                        .scaledToFill()
                } else if theme == .y2k {
                    // Iridescent CD look. The placeholder note is sized off the disc
                    // rather than off Dynamic Type on purpose: it's a stand-in for
                    // missing album art, not text, and the disc is already responsive
                    // to the container — so it grows with the artwork it replaces.
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
        .onAppear { isVisible = true }
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .onChange(of: shouldSpin) { _, spin in
            if spin { startSpin() } else { stopSpin() }
        }
        // keeps "runStartedAt != nil means an animation is live" true if the view is ever
        // torn down and rebuilt, which would otherwise leave the disc frozen
        .onDisappear {
            isVisible = false
            stopSpin()
        }
        .task(id: request) { await loadArtwork(for: request) }
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

    @MainActor
    private func loadArtwork(for request: ArtworkRequest?) async {
        artwork = nil
        guard !Task.isCancelled, let request, request == artworkRequest,
              let song = audioManager.currentSong,
              let url = AudioPlayerManager.url(for: song) else { return }

        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            try Task.checkCancellation()
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
            guard let item = items.first, let data = try await item.load(.dataValue) else { return }
            try Task.checkCancellation()

            let decoding = Task.detached(priority: .userInitiated) { [data, maxPixelSize = request.maxPixelSize] in
                Self.downsample(data, maxPixelSize: maxPixelSize)
            }
            let thumbnail = await withTaskCancellationHandler {
                await decoding.value
            } onCancel: {
                decoding.cancel()
            }
            guard !Task.isCancelled, request == artworkRequest, let thumbnail,
                  let image = UIImage(data: thumbnail) else { return }
            artwork = LoadedArtwork(request: request, image: image)
        } catch is CancellationError {
            return
        } catch {
            Log.playback.debug("Artwork unavailable; using the themed disc")
        }
    }

    nonisolated private static func downsample(_ data: Data, maxPixelSize: Int) -> Data? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              !Task.isCancelled else { return nil }
        // Only a bounded encoded thumbnail crosses executors, not CF objects.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), !Task.isCancelled else { return nil }
        return output as Data
    }
}
