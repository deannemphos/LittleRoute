//
//  QueueDrawerView.swift
//  LittleRoute
//
//  Thin chrome tab pinned to the left edge that slides open when
//  swiped right, revealing the current song queue.
//

import SwiftUI
// for persistentModelID, which the rows below are identified by
import SwiftData

struct QueueDrawerView: View {
    @ObservedObject var audioManager: AudioPlayerManager

    @Binding var isOpen: Bool
    @GestureState private var dragOffset: CGFloat = 0.0

    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.y2k.rawValue
    private var theme: AppTheme { AppTheme.current(from: themeRaw) }

    // The drawer was a flat 370pt (280 before that), which is wider than an
    // iPhone SE's entire screen. The ZStack sized itself to the drawer rather
    // than to the phone and then centred, so on anything narrow the grab tab sat
    // off the left edge and there was no strip of app left to tap to dismiss.
    // Cap it against what the container actually offers instead.
    private static let preferredDrawerWidth: CGFloat = 370.0
    private static let uncoveredScreen: CGFloat = 44.0
    private static let minDrawerWidth: CGFloat = 200.0

    private func drawerWidth(in availableWidth: CGFloat) -> CGFloat {
        min(
            Self.preferredDrawerWidth,
            max(Self.minDrawerWidth, availableWidth - Self.uncoveredScreen)
        )
    }

    // The tab has to keep up with its own chevron...
    @ScaledMetric(relativeTo: .body) private var scaledTabWidth: CGFloat = 20.0
    @ScaledMetric(relativeTo: .body) private var scaledTabHeight: CGFloat = 110.0
    // ...but only so far. It's a sliver on the screen edge, not something that
    // gets easier to grab by eating a third of the width.
    private var tabWidth: CGFloat { min(scaledTabWidth, 34.0) }
    private var tabHeight: CGFloat { min(scaledTabHeight, 160.0) }

    // Current x-offset of the drawer's leading edge
    private func baseOffset(width: CGFloat) -> CGFloat { isOpen ? 0.0 : -width }
    private func currentOffset(width: CGFloat) -> CGFloat {
        min(0.0, max(-width, baseOffset(width: width) + dragOffset))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = drawerWidth(in: proxy.size.width)

            ZStack(alignment: .leading) {
                // Dim the rest of the screen when open
                if isOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isOpen = false } }
                        // a full-screen unlabelled tap target is nothing but a trap in the
                        // rotor; the grab tab stays on screen while open and closes it too
                        .accessibilityHidden(true)
                }

                HStack(spacing: 0) {
                    drawerContent
                        .frame(width: width)

                    // Thin chrome grab tab, always visible at the left edge
                    grabTab
                }
                .offset(x: currentOffset(width: width))
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation.width
                        }
                        .onEnded { value in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                if value.translation.width > 60 { isOpen = true }
                                else if value.translation.width < -60 { isOpen = false }
                            }
                        }
                )
            }
            // pin to the leading edge rather than letting the ZStack centre
            // itself — that centring is what put the tab off screen on an SE
            .frame(width: proxy.size.width, alignment: .leading)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isOpen)
    }

    private var grabTab: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme == .y2k ? AnyShapeStyle(Y2K.chromeGradient) : AnyShapeStyle(Color(.secondarySystemBackground)))
            .frame(width: tabWidth, height: tabHeight)
            .overlay(
                Image(systemName: "chevron.compact.right")
                    .themedFont(.drawerGlyph, theme: theme)
                    .foregroundStyle(theme == .y2k ? Y2K.chromeDark : Color.secondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme == .y2k ? Color.white.opacity(0.7) : Color(.separator), lineWidth: 1))
            .shadow(color: theme == .y2k ? .black.opacity(0.25) : .clear, radius: 3, x: 2)
            .onTapGesture { toggleDrawer() }
            // The drawer is otherwise reachable only by dragging, which VoiceOver takes
            // over for its own gestures, so this 20pt tab is the entire non-visual entry
            // point. Collapse the chevron (which announces as "chevron.compact.right")
            // into one button-shaped element that says what it opens and how it's sitting.
            //
            // The action is spelled out rather than left to ride on the tap gesture above:
            // a synthesized element's activation reaching a plain .onTapGesture is the
            // under-specified path, and this is the only way in. Both routes call the same
            // helper so they can't drift.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Song queue")
            .accessibilityValue(isOpen ? "Open" : "Closed")
            .accessibilityHint(isOpen ? "Closes the queue drawer." : "Opens the queue drawer.")
            .accessibilityAction { toggleDrawer() }
    }

    private func toggleDrawer() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isOpen.toggle() }
    }

    private var drawerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(theme == .y2k ? "☆ UP NEXT ☆" : "Up Next")
                .themedFont(.sectionHeader, theme: theme)
                .foregroundStyle(
                    theme == .y2k
                    ? AnyShapeStyle(LinearGradient(colors: [Y2K.pink, Y2K.purple], startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.primary)
                )
                .shadow(color: theme == .y2k ? .white.opacity(0.8) : .clear, radius: 1, y: 1)
                .padding()
                // same story as the context label: the y2k stars are spoken aloud
                .accessibilityLabel("Up next")
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                LazyVStack(spacing: 8) {
                    // by model ID rather than songName: the store answers "which
                    // row is this", and the name is only a field that happens to
                    // be unique since LR-16
                    ForEach(audioManager.songQueue, id: \.persistentModelID) { song in
                        queueRow(song)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                if theme == .y2k {
                    Y2K.backgroundGradient.opacity(0.95)
                    LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center)
                } else {
                    Color(.systemBackground)
                }
            }
        )
        .overlay(
            Rectangle()
                .fill(theme == .y2k ? AnyShapeStyle(Y2K.chromeGradient) : AnyShapeStyle(Color(.separator)))
                .frame(width: theme == .y2k ? 3 : 1),
            alignment: .trailing
        )
        .ignoresSafeArea(edges: .vertical)
    }

    private func queueRow(_ song: Song) -> some View {
        let isCurrent = audioManager.currentSong?.persistentModelID == song.persistentModelID
        let artist = song.artist ?? "Unknown Artist"
        // the speaker glyph is the only thing marking the playing row, and on its own
        // it reads as its symbol name — fold that state into the row's spoken label
        let spokenLabel = isCurrent ? "Now playing. \(song.title), \(artist)" : "\(song.title), \(artist)"
        return Button {
            audioManager.play(song: song)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .themedFont(.rowTitle, theme: theme)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(rowHighlightText) : AnyShapeStyle(rowText))
                        .lineLimit(1)
                    Text(song.artist ?? "Unknown Artist")
                        .themedFont(.rowSubtitle, theme: theme)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(rowHighlightText.opacity(0.85)) : AnyShapeStyle(rowText.opacity(0.7)))
                        .lineLimit(1)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(rowHighlightText)
                        .accessibilityHidden(true) // said by the row's label instead
                }
            }
            .padding(10)
            .background(
                Capsule()
                    .fill(
                        isCurrent
                        ? (theme == .y2k
                           ? AnyShapeStyle(LinearGradient(colors: [Y2K.pink, Y2K.purple], startPoint: .leading, endPoint: .trailing))
                           : AnyShapeStyle(Color.primary))
                        : (theme == .y2k
                           ? AnyShapeStyle(.white.opacity(0.55))
                           : AnyShapeStyle(Color(.secondarySystemBackground)))
                    )
            )
            .overlay(Capsule().strokeBorder(theme == .y2k ? Color.white.opacity(0.8) : .clear, lineWidth: 1))
        }
        .accessibilityLabel(spokenLabel)
        .accessibilityHint("Plays this song.")
    }

    private var rowText: Color { theme == .y2k ? Y2K.chromeDark : .primary }
    private var rowHighlightText: Color { theme == .y2k ? .white : Color(.systemBackground) }
}
