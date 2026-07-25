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
    var context: AudioPlayerManager.Context
    let diameter: CGFloat
    var color: Color

    @State private var spinning = false
    @State private var bouncing = false

    var body: some View {
        Circle()
            .stroke(
                color.opacity(0.8),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 14])
            )
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .scaleEffect(bouncing ? 1.04 : 0.97)
            .shadow(color: color.opacity(0.5), radius: 6)
            .animation(.easeInOut(duration: 0.6), value: context)
            .onAppear {
                withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                    spinning = true
                }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    bouncing = true
                }
            }
            .allowsHitTesting(false)
    }
}
