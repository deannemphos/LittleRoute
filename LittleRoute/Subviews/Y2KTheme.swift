//
//  Y2KTheme.swift
//  LittleRoute
//
//  Y2K visual theme: chrome gradients, bubblegum pink, cyber cyan,
//  glossy "aqua" buttons with a top highlight.
//

import SwiftUI

enum Y2K {
    static let pink   = Color(red: 1.00, green: 0.45, blue: 0.82)
    static let cyan   = Color(red: 0.35, green: 0.90, blue: 1.00)
    static let purple = Color(red: 0.60, green: 0.40, blue: 1.00)
    static let lime   = Color(red: 0.72, green: 1.00, blue: 0.45)
    static let chromeLight = Color(red: 0.97, green: 0.98, blue: 1.00)
    static let chromeMid   = Color(red: 0.78, green: 0.83, blue: 0.92)
    static let chromeDark  = Color(red: 0.45, green: 0.50, blue: 0.64)

    // Dreamy cyber-sky background
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.55, green: 0.85, blue: 1.00),
                Color(red: 0.75, green: 0.65, blue: 1.00),
                Color(red: 1.00, green: 0.60, blue: 0.88)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // Brushed-metal chrome
    static var chromeGradient: LinearGradient {
        LinearGradient(
            colors: [chromeDark, chromeMid, chromeLight, chromeMid, chromeDark],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// Glossy round "aqua" button (Y2K bubble look)
struct Y2KGlossyButtonStyle: ButtonStyle {
    var size: CGFloat = 64.0
    var tint: Color = Y2K.cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // sized to the bubble, not to Dynamic Type — see the note on
            // ThemedRoundButtonStyle for why the transport glyphs sit this out
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .frame(width: size, height: size)
            .background(
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    // glassy top highlight -- REMOVED FOR NOW, LOOKS LIKE ASS NO MATTER WHAT I TRY
                    /*
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.85), .white.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: size * 0.78, height: size * 0.42)
                        .offset(y: -size * 0.24)
                     */
                }
            )
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [Y2K.chromeLight, Y2K.chromeDark],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
            )
            .shadow(color: tint.opacity(0.6), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// Chrome pill button for secondary actions
struct Y2KPillButtonStyle: ButtonStyle {
    var tint: Color = Y2K.pink
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // the y2k half of the shared .pillLabel role; ThemedPillButtonStyle
            // routes here, so both themes grow at the same rate by construction
            .themedFont(.pillLabel, theme: .y2k)
            .foregroundStyle(isActive ? .white : Y2K.chromeDark)
            .shadow(color: isActive ? .black.opacity(0.3) : .clear, radius: 1, y: 1)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    Capsule()
                        .fill(
                            isActive
                            ? AnyShapeStyle(LinearGradient(
                                colors: [tint.opacity(0.95), tint.opacity(0.6)],
                                startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Y2K.chromeGradient)
                        )
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.7), .white.opacity(0.0)],
                                startPoint: .top, endPoint: .center
                            )
                        )
                        .padding(2)
                }
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
