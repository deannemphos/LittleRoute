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

    func body(content: Content) -> some View {
        if intensity <= 0 {
            content
        } else {
            TimelineView(.periodic(from: .now, by: rate / fps)) { timeline in
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
}

extension View {
    // Overlay animated film grain on this view
    func filmGrain(intensity: Double = 0.08) -> some View {
        modifier(FilmGrainModifier(intensity: intensity))
    }
}
