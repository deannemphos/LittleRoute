//
//  ContextRingView.swift
//  LittleRoute
//
//  A spinning dashed ring with a bouncy looping scale animation.
//  Its color tracks the active music context so the user gets an
//  ambient cue of what zone they're in.
//

import SwiftUI

struct ContextRingView: View {
    var context: MusicContext
    let diameter: CGFloat
    var color: Color
    let isPlaying: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var spinning = false
    @State private var bouncing = false

    private var shouldAnimate: Bool {
        isVisible && scenePhase == .active && !reduceMotion && isPlaying
    }

    var body: some View {
        Circle()
            .stroke(
                color.opacity(0.8),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 14])
            )
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .scaleEffect(reduceMotion ? 1 : (bouncing ? 1.04 : 0.97))
            .shadow(color: color.opacity(0.5), radius: 6)
            .animation(shouldAnimate ? .easeInOut(duration: 0.6) : nil, value: context)
            .onAppear { isVisible = true }
            .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
            .onChange(of: shouldAnimate) { _, animate in
                if animate { startAnimations() } else { stopAnimations() }
            }
            .onDisappear {
                isVisible = false
                stopAnimations()
            }
            .allowsHitTesting(false)
            // purely ambient: the context it's tinted for is spoken by the label
            // right underneath it, so this would just be a stop with nothing to say
            .accessibilityHidden(true)
    }

    private func startAnimations() {
        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
            spinning = true
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            bouncing = true
        }
    }

    private func stopAnimations() {
        withAnimation(nil) {
            spinning = false
            bouncing = false
        }
    }
}
