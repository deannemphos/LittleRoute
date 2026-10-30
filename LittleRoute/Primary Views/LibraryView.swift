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
    // A plain reference to the singleton: the view doesn't own it, and with
    // @Observable a wrapper buys nothing -- SwiftUI tracks whichever properties
    // this body reads on its own.
    private let audioManager = AudioPlayerManager.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelStoreHealth) private var storeHealth

    @Query private var songs: [Song]
    @State private var showFileImporter = false
    @State private var searchText = ""
    @State private var sortByArtist = false
    @State private var replacingExisting = false
    @State private var pendingDeletion: Song?
    // Songs with the context picker shown, held by model ID rather than by
    // songName. The two answer the same question now that songName is
    // constrained unique, but only one of them keeps answering it if a later
    // version ever lets a song be renamed: a set keyed on the name would leave
    // the wrong card open, or none.
    @State private var expandedSongs: Set<PersistentIdentifier> = []

    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.minimal.rawValue
    private var theme: AppTheme { AppTheme.current(from: themeRaw) }

    // The tag grid packs as many chips per row as fit at this width. It has to
    // grow with the chip's own text or the labels start shrinking away as soon
    // as the user turns their text size up.
    @ScaledMetric(relativeTo: .caption) private var chipMinWidth: CGFloat = 92.0

    // Songs whose mp3 lives in the imported music directory.
    //
    // This used to ask the filesystem — a synchronous fileExists per song, on
    // the main thread, re-run every time the List below re-evaluated. The answer
    // is recorded on the model at import time now, so this is a filter over an
    // array that is already in memory.
    //
    // Search/sort affect only visibleSongs. Playback updates independently fetch
    // the complete library, including bundled songs.
    private var importedSongs: [Song] {
        songs.filter(\.isImported)
    }

    private var visibleSongs: [Song] {
        importedSongs.filter { song in
            searchText.isEmpty || song.title.localizedStandardContains(searchText)
                || (song.artist ?? "").localizedStandardContains(searchText)
                || song.songName.localizedStandardContains(searchText)
        }.sorted { left, right in
            let leftFields = sortByArtist
                ? [left.artist ?? "", left.title, left.songName]
                : [left.title, left.artist ?? "", left.songName]
            let rightFields = sortByArtist
                ? [right.artist ?? "", right.title, right.songName]
                : [right.title, right.artist ?? "", right.songName]
            for (lhs, rhs) in zip(leftFields, rightFields) {
                let comparison = lhs.localizedStandardCompare(rhs)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return left.songName < right.songName
        }
    }

    private let allContexts: [MusicContext] = [
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

                if storeHealth.isDegraded {
                    ContentUnavailableView(
                        "Library Unavailable",
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text("Your saved library could not be opened. Importing and editing are disabled to prevent unsaved changes. Your library has not been deleted. Close and reopen LittleRoute to retry.")
                    )
                    .accessibilityIdentifier("libraryUnavailable")
                } else if importedSongs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.house")
                            .themedFont(.emptyStateGlyph, theme: theme)
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityHidden(true) // the two lines below say it in words
                        Text("No imported songs yet")
                            .font(.headline)
                            .foregroundStyle(theme.primaryText)
                        Text("Tap Import to add MP3s from your files.")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    List {
                        // Identified by the model's own ID, not by songName. The
                        // name is unique in the store as of LR-16, so the two
                        // agree — but the ID is the store's answer to "which row
                        // is this" and the name is a field that happens to be
                        // unique, and a List whose rows carry swipe-to-delete
                        // should be reading identity from the former.
                        if visibleSongs.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        }
                        ForEach(visibleSongs, id: \.persistentModelID) { song in
                            songCard(song)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDeletion = song
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .disabled(audioManager.isImporting || storeHealth.isDegraded)
                                }
                        }
                        Section {
                            Text("Automatic place tags: Beaches, Gyms, Restaurants, Stores, Parks and Cities. Rainy and Snowy depend on weather; Traveling covers travel or no nearby place. All is used only when there are no exact context matches. Home, Work, Streets, Driving, Mountains, Towns and Water are preserved tags without automatic detection.")
                                .font(.footnote)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("My Music")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Title, artist or filename")
            .safeAreaInset(edge: .bottom) {
                if !storeHealth.isDegraded, audioManager.isImporting || audioManager.importReport != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if audioManager.isImporting {
                            ProgressView("Importing music", value: audioManager.importProgress)
                        }
                        if let report = audioManager.importReport {
                            ScrollView {
                                Text(report)
                                    .font(.footnote)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                            .accessibilityIdentifier("importReport")
                        }
                        if !audioManager.isImporting {
                            Button("Dismiss Report") { audioManager.importReport = nil }
                        }
                    }
                    .padding()
                    .background(.regularMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import MP3s") {
                            replacingExisting = false
                            showFileImporter = true
                        }
                        Button("Replace Matching Imports") {
                            replacingExisting = true
                            showFileImporter = true
                        }
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .disabled(storeHealth.isDegraded || audioManager.isImporting)
                }
                ToolbarItem(placement: .bottomBar) {
                    Picker("Sort songs", selection: $sortByArtist) {
                        Text("Title").tag(false)
                        Text("Artist").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(storeHealth.isDegraded)
                }
            }
            .confirmationDialog("Delete imported song?", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible, presenting: pendingDeletion) { song in
                Button("Delete Song", role: .destructive) {
                    deleteSong(song)
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { song in
                Text("Remove “\(song.title)” and its imported audio? Keep your original file to import it again. A bundled copy, if present, will be kept.")
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.mp3],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !storeHealth.isDegraded else { return }
                    let replace = replacingExisting
                    Task {
                        await audioManager.importSongs(from: urls, modelContext: modelContext,
                                                       replacingExisting: replace)
                    }
                case .failure(let error):
                    audioManager.importReport = "Could not open the selected files: \(error.localizedDescription). Choose Import to retry."
                }
            }
        }
    }

    // Card showing a song with a collapsible context tag section
    private func songCard(_ song: Song) -> some View {
        let isExpanded = expandedSongs.contains(song.persistentModelID)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if isExpanded {
                        expandedSongs.remove(song.persistentModelID)
                    } else {
                        expandedSongs.insert(song.persistentModelID)
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .themedFont(.cardTitle, theme: theme)
                            .foregroundStyle(theme == .y2k ? Y2K.chromeDark : .primary)
                        Text(song.artist ?? "Unknown Artist")
                            .themedFont(.cardSubtitle, theme: theme)
                            .foregroundStyle(theme == .y2k ? Y2K.chromeDark.opacity(0.7) : .secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .themedFont(.disclosureGlyph, theme: theme)
                        .foregroundStyle(theme == .y2k ? Y2K.chromeDark.opacity(0.7) : .secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true) // its rotation is the disclosure state, said below
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(storeHealth.isDegraded || audioManager.isImporting)
            .accessibilityLabel("\(song.title), \(song.artist ?? "Unknown Artist")")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides the context tags for this song.")

            // Context tag chips (collapsible)
            if isExpanded {
                Text("Imported audio: \(song.songName).mp3")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: chipMinWidth), spacing: 8)], spacing: 8) {
                    // keyed on the storage key rather than the label, so
                    // rewording a chip doesn't tear down and rebuild the grid
                    ForEach(allContexts, id: \.storageKey) { context in
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

    private func contextChip(song: Song, context: MusicContext) -> some View {
        let isTagged = song.isTagged(context)
        return Button {
            toggleTag(song: song, context: context)
        } label: {
            Text(context.displayName)
                .themedFont(.chipLabel, theme: theme)
                .lineLimit(1)
                // context names are single words, so shrinking beats truncating
                // once the chip stops being able to grow with the type
                .minimumScaleFactor(0.75)
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
        .disabled(storeHealth.isDegraded || audioManager.isImporting)
        // whether the tag is on is carried entirely by the capsule fill
        .accessibilityValue(isTagged ? "On" : "Off")
        .accessibilityHint("Toggles whether this song plays in the \(context.displayName) context.")
    }

    private func toggleTag(song: Song, context: MusicContext) {
        guard !storeHealth.isDegraded, !audioManager.isImporting else { return }
        let previousTags = song.locations
        song.setTagged(context, !song.isTagged(context))
        do {
            try modelContext.save()
        } catch {
            song.locations = previousTags
            audioManager.importReport = "Could not save tags for “\(song.title)”: \(error.localizedDescription). Your previous tags were restored; try again."
            return
        }
        do {
            let reader = ModelContext(modelContext.container)
            let library = try reader.fetch(FetchDescriptor<Song>())
            audioManager.reloadQueue(newContext: audioManager.currentContext,
                                     shuffle: audioManager.isShuffled, songs: library)
        } catch {
            audioManager.importReport = "Tags were saved, but playback could not refresh its library: \(error.localizedDescription). Reopen LittleRoute to retry."
        }
    }

    // Delete the song record and its mp3 from the imported music directory
    private func deleteSong(_ song: Song) {
        guard !storeHealth.isDegraded, !audioManager.isImporting else { return }
        let identifier = song.persistentModelID
        if audioManager.deleteImportedSong(song, modelContext: modelContext) {
            expandedSongs.remove(identifier)
        }
    }
}
