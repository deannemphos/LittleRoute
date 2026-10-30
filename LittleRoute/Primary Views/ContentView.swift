import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    private let audioManager = AudioPlayerManager.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.modelStoreHealth) private var storeHealth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @Environment(LocationHandler.self) private var locationHandler
    @Environment(ContextDetector.self) private var contextDetector
    @State private var queueDrawerOpen = false
    @State private var showLibrary = false
    @State private var showFileImporter = false
    @State private var showExpandedMap = false
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.minimal.rawValue
    @ScaledMetric(relativeTo: .caption) private var arcScaleProbe: CGFloat = CurvedText.Metrics.probeBase

    private var theme: AppTheme { AppTheme.current(from: themeRaw) }
    private var arcScale: CGFloat { CurvedText.Metrics.scale(fromProbe: arcScaleProbe) }
    private var arcReach: CGFloat { 18 * arcScale + CurvedText.Metrics.glyphOverhang(fontSize: 14 * arcScale) }

    var body: some View {
        ZStack {
            Color.clear.background(theme.background).ignoresSafeArea()
            GeometryReader { proxy in
                let diameter = max(150, min(320, min(proxy.size.width - 2 * (8 + arcReach), proxy.size.height * 0.42)))
                ScrollView {
                    VStack(spacing: 12) {
                        header
                        discStack(diameter: diameter).padding(.top, dynamicTypeSize.isAccessibilitySize ? 8 : max(30, arcReach))
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack {
                                Text(audioManager.currentSong?.title ?? "No song playing").font(.headline)
                                Text(audioManager.currentSong?.artist ?? "").font(.subheadline)
                            }
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        }
                        PlaybackProgressView(audioManager: audioManager).frame(width: diameter)
                        playbackControls
                        secondaryControls
                        ContextStatusView(contextDetector: contextDetector, audioManager: audioManager)
                        locationStatus
                        Toggle("Variety", isOn: Binding(get: { contextDetector.varietyEnabled }, set: contextDetector.setVarietyEnabled))
                            .accessibilityHint("Off follows stable geographic zones. On also allows time-based variety after confirmation.")
                        if audioManager.isImporting {
                            ProgressView("Importing songs", value: audioManager.importProgress)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 44)
                    .padding(.bottom)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            QueueDrawerView(audioManager: audioManager, isOpen: $queueDrawerOpen)
            topBar
        }
        .safeAreaInset(edge: .bottom) {
            if storeHealth.isDegraded {
                Label("Your library could not be opened. Importing and editing are unavailable; your saved library has not been deleted. Close and reopen LittleRoute to retry.", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout).padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .accessibilityIdentifier("libraryStoreWarning")
            }
        }
        .sheet(isPresented: $showLibrary) { LibraryView() }
        .fullScreenCover(isPresented: $showExpandedMap) {
            ExpandedContextMap(contextDetector: contextDetector, audioManager: audioManager)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.mp3], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await audioManager.importSongs(from: urls, modelContext: modelContext) }
            case .failure(let error):
                audioManager.importReport = "The selected files could not be opened: \(error.localizedDescription)"
            }
        }
        .alert("LittleRoute", isPresented: Binding(
            get: { audioManager.playbackError != nil || audioManager.importReport != nil },
            set: { if !$0 { audioManager.playbackError = nil; audioManager.importReport = nil } }
        )) {
            Button("OK") { audioManager.playbackError = nil; audioManager.importReport = nil }
        } message: {
            Text(audioManager.playbackError ?? audioManager.importReport ?? "")
        }
        .onAppear {
            if !PlaybackCoordinator.isTesting { locationHandler.requestLocationAuthorization() }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("LittleRoute")
                .themedFont(.wordmark, theme: theme)
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(theme.titleStyle)
                .accessibilityAddTraits(.isHeader)
            ContextRingView(context: audioManager.currentContext, diameter: 24, color: audioManager.currentContext.tintColor)
            Text(audioManager.currentContext.displayName)
                .themedFont(.contextLabel, theme: theme)
                .foregroundStyle(theme.secondaryText)
                .accessibilityLabel("Current music context, \(audioManager.currentContext.displayName)")
        }
    }

    private func discStack(diameter: CGFloat) -> some View {
        ZStack {
            // Only one interactive map is alive while the expanded map is open.
            if !showExpandedMap {
                SpinningAlbumView(audioManager: audioManager, diameter: diameter)
                MapView(contextDetector: contextDetector, context: audioManager.currentContext)
                    .frame(width: diameter * 0.8125, height: diameter * 0.8125)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(theme.rim, lineWidth: theme.rimWidth))
                    .shadow(color: theme.shadowColor, radius: 8)
            } else {
                Circle().fill(Color(.secondarySystemBackground)).frame(width: diameter, height: diameter)
            }
            if !dynamicTypeSize.isAccessibilitySize {
                CurvedText(text: audioManager.currentSong?.title ?? "No song playing",
                           radius: diameter / 2 + 18 * arcScale, fontSize: 14,
                           color: theme.primaryText,
                           spokenLabel: "Now playing, \(audioManager.currentSong?.title ?? "no song")")
                CurvedText(text: audioManager.currentSong?.artist ?? "Unknown Artist",
                           radius: diameter / 2 + 8 * arcScale, fontSize: 12,
                           color: theme.secondaryText,
                           spokenLabel: "Artist, \(audioManager.currentSong?.artist ?? "unknown")")
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 28) {
            Button { audioManager.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(ThemedRoundButtonStyle(theme: theme, size: 60, tint: Y2K.purple))
                .accessibilityLabel("Previous song")
            Button { audioManager.musicPlayPause() } label: {
                Image(systemName: audioManager.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(ThemedRoundButtonStyle(theme: theme, size: 80, tint: Y2K.pink))
            .accessibilityLabel(audioManager.isPaused ? "Play" : "Pause")
            Button { audioManager.skip() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(ThemedRoundButtonStyle(theme: theme, size: 60, tint: Y2K.purple))
                .accessibilityLabel("Next song")
        }
        .disabled(audioManager.songQueue.isEmpty)
    }

    private var secondaryControls: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { shuffleButton; refreshButton }
                VStack { shuffleButton; refreshButton }
            }
            ViewThatFits(in: .horizontal) {
                HStack { expandButton; queueButton }
                VStack { expandButton; queueButton }
            }
            .buttonStyle(.bordered)
        }
    }

    private var shuffleButton: some View {
        Button { audioManager.toggleShuffle() } label: { Label("Shuffle", systemImage: "shuffle") }
            .buttonStyle(ThemedPillButtonStyle(theme: theme, tint: Y2K.cyan, isActive: audioManager.isShuffled))
            .accessibilityValue(audioManager.isShuffled ? "On" : "Off")
    }

    private var refreshButton: some View {
        Button { contextDetector.refreshNow() } label: {
            Label(contextDetector.isSearching ? "Refreshing" : "Refresh Zones", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(ThemedPillButtonStyle(theme: theme, tint: Y2K.lime))
        .disabled(contextDetector.isSearching)
        .accessibilityHint("Refreshes nearby zones without bypassing stable switching.")
    }

    private var expandButton: some View {
        Button { showExpandedMap = true } label: {
            Label("Expand Map", systemImage: "arrow.up.left.and.arrow.down.right").frame(minHeight: 44)
        }
        .accessibilityIdentifier("expandContextMap")
    }

    private var queueButton: some View {
        Button { queueDrawerOpen.toggle() } label: { Label("Queue", systemImage: "list.bullet").frame(minHeight: 44) }
            .accessibilityIdentifier("openQueue")
    }

    @ViewBuilder private var locationStatus: some View {
        if let message = locationHandler.locationMessage {
            Text(message).font(.callout).multilineTextAlignment(.center)
            Button("Open Location Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .frame(minHeight: 44)
        }
        if locationHandler.authorizationStatus == .authorizedWhenInUse {
            Button("Enable Background Adaptation") { locationHandler.requestBackgroundAuthorization() }
                .frame(minHeight: 44)
                .accessibilityHint("Requests permission to keep adapting music when your phone is locked.")
        }
    }

    private var topBar: some View {
        VStack {
            HStack {
                Button { showLibrary = true } label: {
                    Image(systemName: "music.note.list").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Music library")
                .accessibilityIdentifier("openLibrary")
                Button { showFileImporter = true } label: {
                    Image(systemName: "plus.circle").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Import songs")
                .disabled(storeHealth.isDegraded || audioManager.isImporting)
                Spacer()
                Button { themeRaw = theme.next.rawValue } label: {
                    Image(systemName: "paintbrush.fill").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Change theme")
                .accessibilityValue(theme.rawValue)
                .accessibilityHint("Switches to \(theme.next.rawValue).")
            }
            .padding(.horizontal)
            .background(.regularMaterial)
            Spacer()
        }
    }
}
