//
//  Theme.swift
//  LittleRoute
//
//  App-wide theme selection. Persisted via @AppStorage(AppTheme.storageKey).
//  Tokens switch between the Y2K look and a flat, monochrome Minimal look.
//

import SwiftUI

enum AppTheme: String, CaseIterable {
    case y2k = "Y2K"
    case minimal = "Minimal"

    static let storageKey = "appTheme"

    var next: AppTheme {
        let all = AppTheme.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    // MARK: - Tokens
    var background: AnyShapeStyle {
        self == .y2k ? AnyShapeStyle(Y2K.backgroundGradient) : AnyShapeStyle(Color(.systemBackground))
    }
    var grainIntensity: Double { self == .y2k ? 0.08 : 0.0 }

    var titleStyle: AnyShapeStyle {
        self == .y2k ? AnyShapeStyle(Y2K.chromeGradient) : AnyShapeStyle(Color.primary)
    }
    var titleGlow: Color { self == .y2k ? Y2K.purple.opacity(0.5) : .clear }

    var primaryText: Color { self == .y2k ? .white : .primary }
    var secondaryText: Color { self == .y2k ? .white.opacity(0.8) : .secondary }

    var accent: Color { self == .y2k ? Y2K.pink : .primary }
    var controlTint: Color { self == .y2k ? Y2K.purple : .primary }

    var rim: AnyShapeStyle {
        self == .y2k ? AnyShapeStyle(Y2K.chromeGradient) : AnyShapeStyle(Color(.separator))
    }
    var rimWidth: CGFloat { self == .y2k ? 2.0 : 1.0 }
    var shadowColor: Color { self == .y2k ? .black.opacity(0.35) : .clear }
}

// Convenience for reading the persisted theme in any view
extension AppTheme {
    static func current(from rawValue: String) -> AppTheme {
        AppTheme(rawValue: rawValue) ?? .y2k
    }
}

// Round playback button — glossy in Y2K, flat circle in Minimal
struct ThemedRoundButtonStyle: ButtonStyle {
    var theme: AppTheme
    var size: CGFloat = 64.0
    var tint: Color = Y2K.cyan

    func makeBody(configuration: Configuration) -> some View {
        if theme == .y2k {
            Y2KGlossyButtonStyle(size: size, tint: tint).makeBody(configuration: configuration)
        } else {
            configuration.label
                .font(.system(size: size * 0.34, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color(.secondarySystemBackground)))
                .opacity(configuration.isPressed ? 0.5 : 1.0)
        }
    }
}

// Pill button — chrome in Y2K, thin outline in Minimal
struct ThemedPillButtonStyle: ButtonStyle {
    var theme: AppTheme
    var tint: Color = Y2K.pink
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        if theme == .y2k {
            Y2KPillButtonStyle(tint: tint, isActive: isActive).makeBody(configuration: configuration)
        } else {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.primary))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isActive ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.clear))
                )
                .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 1))
                .opacity(configuration.isPressed ? 0.5 : 1.0)
        }
    }
}
