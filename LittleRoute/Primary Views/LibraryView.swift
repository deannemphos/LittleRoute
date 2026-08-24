//
//  LibraryView.swift
//  LittleRoute
//
//  Viewer for user-imported songs (Documents/Music). Lets the user
//  import new MP3s and tag each song with the contexts it should play in.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var songs: [Song]
    @State private var showFileImporter = false
    @State private var expandedSongs: Set<String> = [] // songNames with the context picker shown

    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.minimal.rawValue
    private var theme: AppTheme { AppTheme.current(from: themeRaw) }

    // Songs whose mp3 lives in the imported music directory
    private var importedSongs: [Song] {
        songs.filter { song in
            FileManager.default.fileExists(
                atPath: AudioPlayerManager.importedMusicDirectory
                    .appendingPathComponent("\(song.songName).mp3").path
            )
        }
    }

    private let allContexts: [AudioPlayerManager.Context] = [
        .all, .gym, .restaurant, .store, .park, .home, .work,
        .street, .driving, .beach, .mountain, .city, .town, .water,
        .rainy, .snowy, .traveling
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear
                    .background(theme.background)
                    .filmGrain(intensity: theme.grainIntensity)
                    .ignoresSafeArea()

                if importedSongs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.house")
                            .font(.system(size: 44))
                            .foregroundStyle(theme.secondaryText)
                        Text("No imported songs yet")
                            .font(.headline)
                            .foregroundStyle(theme.primaryText)
                        Text("Tap Import to add MP3s from your files.")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    List {
                        ForEach(importedSongs, id: \.songName) { song in
                            songCard(song)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteSong(song)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("My Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                }
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
        }
    }

    // Card showing a song with a collapsible context tag section
    private func songCard(_ song: Song) -> some View {
        let isExpanded = expandedSongs.contains(song.songName)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if isExpanded {
                        expandedSongs.remove(song.songName)
                    } else {
                        expandedSongs.insert(song.songName)
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.system(size: 16, weight: .semibold, design: theme == .y2k ? .rounded : .default))
                            .foregroundStyle(theme == .y2k ? Y2K.chromeDark : .primary)
                        Text(song.artist ?? "Unknown Artist")
                            .font(.system(size: 13))
                            .foregroundStyle(theme == .y2k ? Y2K.chromeDark.opacity(0.7) : .secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme == .y2k ? Y2K.chromeDark.opacity(0.7) : .secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Context tag chips (collapsible)
            if isExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(allContexts, id: \.rawValue) { context in
                        contextChip(song: song, context: context)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme == .y2k ? AnyShapeStyle(Color.white.opacity(0.55)) : AnyShapeStyle(Color(.secondarySystemBackground)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme == .y2k ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(Color(.separator)), lineWidth: 1)
        )
    }

    private func contextChip(song: Song, context: AudioPlayerManager.Context) -> some View {
        let isTagged = song.locations.contains(context.rawValue)
        return Button {
            toggleTag(song: song, context: context)
        } label: {
            Text(context.rawValue)
                .font(.system(size: 12, weight: .semibold, design: theme == .y2k ? .rounded : .default))
                .lineLimit(1)
                .foregroundStyle(
                    isTagged
                    ? (theme == .y2k ? Color.white : Color(.systemBackground))
                    : (theme == .y2k ? Y2K.chromeDark : .primary)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(
                        isTagged
                        ? (theme == .y2k
                           ? AnyShapeStyle(LinearGradient(colors: [Y2K.pink, Y2K.purple], startPoint: .leading, endPoint: .trailing))
                           : AnyShapeStyle(Color.primary))
                        : AnyShapeStyle(Color.clear)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        theme == .y2k ? AnyShapeStyle(Y2K.chromeGradient) : AnyShapeStyle(Color(.separator)),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func toggleTag(song: Song, context: AudioPlayerManager.Context) {
        if let index = song.locations.firstIndex(of: context.rawValue) {
            song.locations.remove(at: index)
        } else {
            song.locations.append(context.rawValue)
        }
        try? modelContext.save()
        // Refresh the queue so tag changes take effect immediately
        audioManager.reloadQueue(newContext: audioManager.currentContext, shuffle: audioManager.isShuffled, songs: songs)
    }

    // Delete the song record and its mp3 from the imported music directory
    private func deleteSong(_ song: Song) {
        let fileURL = AudioPlayerManager.importedMusicDirectory
            .appendingPathComponent("\(song.songName).mp3")
        try? FileManager.default.removeItem(at: fileURL)

        expandedSongs.remove(song.songName)
        modelContext.delete(song)
        try? modelContext.save()

        // Refresh the queue so the deleted song can't keep playing from it
        audioManager.reloadQueue(newContext: audioManager.currentContext, shuffle: audioManager.isShuffled, songs: songs.filter { $0 !== song })
    }
}
