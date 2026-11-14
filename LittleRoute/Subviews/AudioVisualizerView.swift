import SwiftUI

/// Spectrum bars for the main view. Decorative: hidden from VoiceOver, and the
/// audio tap only runs while the bars are visible, moving and audible.
struct AudioVisualizerView: View {
    let isPlaying: Bool
    var tint: Color
    var height: CGFloat = 36

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    private let graph = AudioGraph.shared

    private var isActive: Bool {
        isVisible && scenePhase == .active && !reduceMotion && isPlaying
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(graph.levels.indices, id: \.self) { band in
                Capsule()
                    .fill(tint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 3 + (height - 3) * CGFloat(isActive ? graph.levels[band] : 0))
            }
        }
        .frame(height: height, alignment: .bottom)
        // Tap buffers arrive 10-40 times a second; this fills in between them.
        .animation(.linear(duration: 0.1), value: graph.levels)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .onDisappear {
            isVisible = false
            graph.setVisualizing(false)
        }
        .onChange(of: isActive, initial: true) { _, active in graph.setVisualizing(active) }
    }
}
