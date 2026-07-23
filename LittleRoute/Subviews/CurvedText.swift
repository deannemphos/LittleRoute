//
//  CurvedText.swift
//  LittleRoute
//
//  Renders text along an arc, centered at the top of a circle.
//  Used to wrap the song title and artist around the album disc.
//

import SwiftUI

struct CurvedText: View {
    let text: String
    let radius: CGFloat
    var fontSize: CGFloat = 18.0
    var color: Color = .white

    // Approximate angular width of one character at this radius (radians)
    private var anglePerChar: Double {
        Double(fontSize * 0.62 / radius)
    }

    var body: some View {
        let chars = Array(text)
        let total = anglePerChar * Double(chars.count)

        ZStack {
            ForEach(chars.indices, id: \.self) { index in
                // angle of this char, centered around the top (0 = straight up)
                let angle = -total / 2 + anglePerChar * (Double(index) + 0.5)
                Text(String(chars[index]))
                    .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .offset(y: -radius)
                    .rotationEffect(.radians(angle))
            }
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}
