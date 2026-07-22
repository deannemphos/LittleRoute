//
//  QueueDrawerView.swift
//  LittleRoute
//
//  Thin chrome tab pinned to the left edge that slides open when
//  swiped right, revealing the current song queue.
//

import SwiftUI

struct QueueDrawerView: View {
    @ObservedObject var audioManager: AudioPlayerManager

    @Binding var isOpen: Bool
    @GestureState private var dragOffset: CGFloat = 0.0

    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.y2k.rawValue
    private var theme: AppTheme { AppTheme.current(from: themeRaw) }

    // private let drawerWidth: CGFloat = 280.0
    private let drawerWidth: CGFloat = 370.0
    private let tabWidth: CGFloat = 20.0

    // Current x-offset of the drawer's leading edge
    private var baseOffset: CGFloat { isOpen ? 0.0 : -drawerWidth }
    private var currentOffset: CGFloat {
        min(0.0, max(-drawerWidth, baseOffset + dragOffset))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Dim the rest of the screen when open
            if isOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isOpen = false } }
            }

            HStack(spacing: 0) {
                drawerContent
                    .frame(width: drawerWidth)

                // Thin chrome grab tab, always visible at the left edge
                grabTab
            }
            .offset(x: currentOffset)
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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isOpen)
    }

    private var grabTab: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme == .y2k ? AnyShapeStyle(Y2K.chromeGradient) : AnyShapeStyle(Color(.secondarySystemBackground)))
            .frame(width: tabWidth, height: 110)
            .overlay(
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme == .y2k ? Y2K.chromeDark : Color.secondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme == .y2k ? Color.white.opacity(0.7) : Color(.separator), lineWidth: 1))
            .shadow(color: theme == .y2k ? .black.opacity(0.25) : .clear, radius: 3, x: 2)
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isOpen.toggle() }
            }
    }

    private var drawerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(theme == .y2k ? "☆ UP NEXT ☆" : "Up Next")
                .font(.system(size: 20, weight: theme == .y2k ? .black : .semibold, design: theme == .y2k ? .rounded : .default))
                .foregroundStyle(
                    theme == .y2k
                    ? AnyShapeStyle(LinearGradient(colors: [Y2K.pink, Y2K.purple], startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.primary)
                )
                .shadow(color: theme == .y2k ? .white.opacity(0.8) : .clear, radius: 1, y: 1)
                .padding()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(audioManager.songQueue, id: \.songName) { song in
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
        let isCurrent = audioManager.currentSong?.songName == song.songName
        return Button {
            audioManager.play(song: song)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 15, weight: theme == .y2k ? .bold : .medium, design: theme == .y2k ? .rounded : .default))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(rowHighlightText) : AnyShapeStyle(rowText))
                        .lineLimit(1)
                    Text(song.artist ?? "Unknown Artist")
                        .font(.system(size: 12, weight: .medium, design: theme == .y2k ? .rounded : .default))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(rowHighlightText.opacity(0.85)) : AnyShapeStyle(rowText.opacity(0.7)))
                        .lineLimit(1)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(rowHighlightText)
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
    }

    private var rowText: Color { theme == .y2k ? Y2K.chromeDark : .primary }
    private var rowHighlightText: Color { theme == .y2k ? .white : Color(.systemBackground) }
}
