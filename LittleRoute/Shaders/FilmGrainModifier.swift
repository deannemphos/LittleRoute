//
//  FilmGrainModifier.swift
//  LittleRoute
//
//  Applies the FilmGrain.metal color effect with a flickering
//  time parameter
//

import SwiftUI

struct FilmGrainModifier: ViewModifier {
    var intensity: Double = 0.08
    var fps: Double = 24.0   // Default to 24
    var rate: Double = 1.0  // Default to 1.0

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    private var shouldAnimate: Bool {
        isVisible && scenePhase == .active && !reduceMotion
    }

    func body(content: Content) -> some View {
        Group {
            if !intensity.isFinite || intensity <= 0 || !fps.isFinite || fps <= 0 || !rate.isFinite || rate <= 0 {
                content
            } else {
                TimelineView(.animation(minimumInterval: rate / fps, paused: !shouldAnimate)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    content
                        .colorEffect(
                            ShaderLibrary.filmGrain(
                                .float(Float(time.truncatingRemainder(dividingBy: 100.0))),
                                .float(Float(intensity))
                            )
                        )
                }
            }
        }
        .onAppear { isVisible = true }
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .onDisappear { isVisible = false }
    }
}

extension View {
    // Overlay animated film grain on this view
    func filmGrain(intensity: Double = 0.08) -> some View {
        modifier(FilmGrainModifier(intensity: intensity))
    }
}
