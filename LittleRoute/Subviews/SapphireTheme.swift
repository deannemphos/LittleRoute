//
//  SapphireTheme.swift
//  LittleRoute
//
//  Sapphire visual theme: one loud cobalt, drawn in the language of the
//  Game Boy Advance era. Cream dialog panels with a double border, a
//  "now entering" area sign, a battle-style info box whose bar drains as
//  the song plays, and chunky buttons that sit on a hard drop shadow and
//  press down into it. No gloss, no gradients.
//

import SwiftUI

enum Sapphire {
    static let sapphire  = rgb(0x2357FF)   // ground
    static let deepSea   = rgb(0x0B1B5C)   // ink, every outline
    static let water     = rgb(0x1438C8)
    static let platform  = rgb(0x7FA8FF)   // battle platform under the disc
    static let platformShade = rgb(0x5C8BFF)
    static let rim       = rgb(0x9DBBFF)   // inner band of the dialog border
    static let mist      = rgb(0xDCE6FF)
    static let dialog    = rgb(0xFFFBEA)   // panel fill
    static let volt      = rgb(0xFFD02E)   // play button, cursor, the one hot accent
    static let inkSoft   = rgb(0x3A4A8C)
    static let dot       = rgb(0x3B6BFF)   // background dot grid

    // the time bar reads like an HP bar: it drains, and changes colour as it does
    static let barFull   = rgb(0x3CE07A)
    static let barHalf   = rgb(0xFFC93C)
    static let barLow    = rgb(0xFF5A5A)
    static let barTrack  = rgb(0x2A3566)

    static let border: CGFloat = 3.0
    static let drop: CGFloat = 5.0

    static func barColor(remaining: Double) -> Color {
        remaining > 0.5 ? barFull : (remaining > 0.2 ? barHalf : barLow)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Background

// Flat cobalt with a fine dot grid, the way Gen-3 menus tiled a pattern
// behind their panels. Drawn once into a Canvas rather than as hundreds of views.
struct SapphireBackground: View {
    var spacing: CGFloat = 14.0
    var dotRadius: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Sapphire.sapphire))
            var dots = Path()
            var y = spacing / 2.0
            while y < size.height {
                var x = spacing / 2.0
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(Sapphire.dot))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Panels

// The dialog box: cream fill, ink border, a pale inner band, and a hard drop.
struct SapphirePanel: ViewModifier {
    var cornerRadius: CGFloat = 18.0
    var fill: Color = Sapphire.dialog
    var drop: CGFloat = 6.0

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Sapphire.rim, lineWidth: Sapphire.border * 2))
            .overlay(shape.strokeBorder(Sapphire.deepSea, lineWidth: Sapphire.border))
            .background(shape.fill(Sapphire.deepSea).offset(y: drop))
    }
}

extension View {
    func sapphirePanel(cornerRadius: CGFloat = 18.0, fill: Color = Sapphire.dialog, drop: CGFloat = 6.0) -> some View {
        modifier(SapphirePanel(cornerRadius: cornerRadius, fill: fill, drop: drop))
    }
}

// MARK: - Buttons

// Round transport button. Sits on its own shadow and sinks into it when pressed.
struct SapphireRoundButtonStyle: ButtonStyle {
    var size: CGFloat = 64.0
    var fill: Color = Sapphire.dialog

    func makeBody(configuration: Configuration) -> some View {
        let isHero = size >= 80.0
        let drop: CGFloat = isHero ? 6.0 : Sapphire.drop
        let border: CGFloat = isHero ? 4.0 : Sapphire.border
        return configuration.label
            // sized to the button, not Dynamic Type — see ThemedRoundButtonStyle
            .font(.system(size: size * 0.36, weight: .heavy))
            .foregroundStyle(Sapphire.deepSea)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(Sapphire.deepSea, lineWidth: border))
            .offset(y: configuration.isPressed ? drop - 1.0 : 0.0)
            // applied after the offset so the shadow stays put while the face sinks
            .background(Circle().fill(Sapphire.deepSea).offset(y: drop))
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// Pill for shuffle / update context. Active = filled ink.
struct SapphirePillButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let drop: CGFloat = 4.0
        return configuration.label
            .themedFont(.pillLabel, theme: .sapphire)
            .foregroundStyle(isActive ? Color.white : Sapphire.deepSea)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Capsule().fill(isActive ? Sapphire.deepSea : Sapphire.dialog))
            .overlay(Capsule().strokeBorder(Sapphire.deepSea, lineWidth: Sapphire.border))
            .offset(y: configuration.isPressed ? drop - 1.0 : 0.0)
            .background(Capsule().fill(isActive ? Sapphire.water : Sapphire.deepSea).offset(y: drop))
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// Top-bar glyphs: bare in the other themes, a cream key-cap in Sapphire.
struct TopBarGlyphStyle: ViewModifier {
    var theme: AppTheme

    func body(content: Content) -> some View {
        if theme == .sapphire {
            content
                .themedFont(.controlGlyph, theme: theme)
                .fontWeight(.bold)
                .foregroundStyle(Sapphire.deepSea)
                .frame(width: 44, height: 44)
                .sapphirePanel(cornerRadius: 12, drop: 4)
                .padding(4)
        } else {
            content
                .themedFont(.controlGlyph, theme: theme)
                .foregroundStyle(theme.secondaryText)
                .padding(10)
        }
    }
}

// MARK: - Area sign

// The "now entering" sign that drops in when you walk into a new area.
// Keyed on the context, so a switch re-runs the drop-in.
struct SapphireAreaSign: View {
    var context: MusicContext

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: context.iconName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Sapphire.volt)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Sapphire.sapphire))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("NOW ENTERING")
                    .themedFont(.chipLabel, theme: .sapphire)
                    .tracking(1.5)
                    .foregroundStyle(Sapphire.inkSoft)
                Text(context.displayName.uppercased())
                    .themedFont(.contextLabel, theme: .sapphire)
                    .tracking(1)
                    .foregroundStyle(Sapphire.deepSea)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .sapphirePanel(cornerRadius: 10, drop: 5)
        .id(context)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current context, \(context.displayName)")
    }
}

// MARK: - Battle info box

// Now-playing card with a draining time bar, after the battle HUD.
struct SapphireInfoBox: View {
    var title: String
    var artist: String
    var number: Int?
    var currentTime: TimeInterval
    var songLength: TimeInterval
    var progress: Double

    private var remaining: Double { max(0.0, min(1.0, 1.0 - progress)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .themedFont(.cardTitle, theme: .sapphire)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let number {
                    Text(String(format: "No.%03d", number))
                        .themedFont(.contextLabel, theme: .sapphire)
                        .foregroundStyle(Sapphire.water)
                        .accessibilityHidden(true)
                }
            }
            Text(artist)
                .themedFont(.cardSubtitle, theme: .sapphire)
                .foregroundStyle(Sapphire.inkSoft)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text("TIME")
                    .themedFont(.chipLabel, theme: .sapphire)
                    .foregroundStyle(Sapphire.volt)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Sapphire.deepSea))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Sapphire.barTrack)
                        Capsule()
                            .fill(Sapphire.barColor(remaining: remaining))
                            .frame(width: proxy.size.width * remaining)
                            .animation(.linear(duration: 0.5), value: remaining)
                    }
                }
                .frame(height: 12)
                .padding(Sapphire.border)
                .background(Capsule().fill(Sapphire.deepSea))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback progress")
            .accessibilityValue("\(Self.clock(currentTime)) of \(Self.clock(songLength))")

            Text("\(Self.clock(currentTime)) / \(Self.clock(songLength))")
                .themedFont(.pillLabel, theme: .sapphire)
                .fontDesign(.monospaced)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Sapphire.deepSea)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .sapphirePanel()
    }

    static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Vinyl

// Missing-artwork disc for Sapphire: ink vinyl with grooves.
struct SapphireVinyl: View {
    var diameter: CGFloat

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(ellipseIn: rect), with: .color(Sapphire.deepSea))
            let step = max(4.0, diameter * 0.022)
            var r = size.width / 2.0 - step
            while r > size.width * 0.16 {
                let groove = CGRect(x: size.width / 2.0 - r, y: size.height / 2.0 - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: groove), with: .color(Sapphire.water.opacity(0.45)), lineWidth: 1.2)
                r -= step
            }
            // the yellow marker is what makes the spin readable on a plain disc
            let m = diameter * 0.08
            context.fill(
                Path(ellipseIn: CGRect(x: size.width * 0.16, y: size.height * 0.16, width: m, height: m)),
                with: .color(Sapphire.volt)
            )
        }
    }
}
