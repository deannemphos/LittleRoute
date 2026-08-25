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

// MARK: - Dynamic Type plumbing

// System font at `size`, scaled along `textStyle`'s Dynamic Type curve.
//
// SwiftUI's `Font.system(size:)` is frozen at whatever number you hand it, and
// `relativeTo:` only exists on `Font.custom` — which needs a real font name, so
// it's no help for the system face. `@ScaledMetric` is the piece that actually
// reads the user's text-size setting out of the environment, and it has to live
// on a view, which is why this is a modifier and not a `Font` extension.
struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, relativeTo textStyle: Font.TextStyle, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    func scaledFont(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledSystemFont(size: size, relativeTo: textStyle, weight: weight, design: design))
    }
}

// MARK: - Type scale
//
// Every font in the app used to be a fixed `.system(size:)`, so the text-size
// setting did nothing at all. Rather than fix that up one call site at a time,
// the sizes live here as named roles — because the *weight and design* half of
// each font was already a theme decision (Y2K is rounded and heavy, Minimal is
// plain) and that same ternary was being copy-pasted into every view. One token,
// one place to retune, and the two themes can't drift apart by accident.
extension AppTheme {
    enum TypeRole {
        case wordmark           // "LittleRoute"
        case contextLabel       // current context, under the wordmark
        case sectionHeader      // "UP NEXT"
        case rowTitle           // queue row, song title
        case rowSubtitle        // queue row, artist
        case cardTitle          // library card, song title
        case cardSubtitle       // library card, artist
        case chipLabel          // library context tag
        case pillLabel          // shuffle / update-context buttons
        case controlGlyph       // top-bar SF Symbols
        case disclosureGlyph    // library card chevron
        case drawerGlyph        // queue grab-tab chevron
        case emptyStateGlyph    // library empty-state icon
    }

    // Base point size plus the system text style whose curve it rides. The style
    // is picked for its *rate of growth*, not to match the size: big display type
    // rides the shallow largeTitle curve so the wordmark doesn't eat the screen,
    // while small print rides caption, which grows hardest where it's needed most.
    private func typeSize(_ role: TypeRole) -> (size: CGFloat, style: Font.TextStyle) {
        switch role {
        case .wordmark:        return (38.0, .largeTitle)
        case .contextLabel:    return (15.0, .subheadline)
        case .sectionHeader:   return (20.0, .title3)
        case .rowTitle:        return (15.0, .subheadline)
        case .rowSubtitle:     return (12.0, .caption)
        case .cardTitle:       return (16.0, .callout)
        case .cardSubtitle:    return (13.0, .footnote)
        case .chipLabel:       return (12.0, .caption)
        case .pillLabel:       return (14.0, .footnote)
        case .controlGlyph:    return (16.0, .body)
        case .disclosureGlyph: return (13.0, .footnote)
        case .drawerGlyph:     return (18.0, .body)
        case .emptyStateGlyph: return (44.0, .largeTitle)
        }
    }

    private func typeWeight(_ role: TypeRole) -> Font.Weight {
        let isY2K = self == .y2k
        switch role {
        case .wordmark:        return isY2K ? .black : .semibold
        case .contextLabel:    return isY2K ? .bold : .regular
        case .sectionHeader:   return isY2K ? .black : .semibold
        case .rowTitle:        return isY2K ? .bold : .medium
        case .pillLabel:       return isY2K ? .heavy : .medium
        case .rowSubtitle:     return .medium
        case .cardTitle:       return .semibold
        case .cardSubtitle:    return .regular
        case .chipLabel:       return .semibold
        case .disclosureGlyph: return .semibold
        case .drawerGlyph:     return .bold
        case .controlGlyph:    return .regular
        case .emptyStateGlyph: return .regular
        }
    }

    // Y2K is the rounded one. Glyph roles stay on the default face regardless:
    // SF Symbols have no rounded cut, so asking for one just does nothing.
    private func typeDesign(_ role: TypeRole) -> Font.Design {
        switch role {
        case .controlGlyph, .disclosureGlyph, .drawerGlyph, .emptyStateGlyph:
            return .default
        default:
            return self == .y2k ? .rounded : .default
        }
    }

    func typeMetrics(_ role: TypeRole) -> (size: CGFloat, style: Font.TextStyle, weight: Font.Weight, design: Font.Design) {
        let base = typeSize(role)
        return (base.size, base.style, typeWeight(role), typeDesign(role))
    }
}

extension View {
    // Apply a theme type role. Scales with the user's text-size setting.
    func themedFont(_ role: AppTheme.TypeRole, theme: AppTheme) -> some View {
        let metrics = theme.typeMetrics(role)
        return scaledFont(
            size: metrics.size,
            relativeTo: metrics.style,
            weight: metrics.weight,
            design: metrics.design
        )
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
                // deliberately NOT Dynamic Type: this glyph is sized to the button
                // it sits in, and the button is a fixed 60/80pt hit target. Letting
                // the arrow grow past its own circle would look broken without
                // making anything easier to hit — the target is already well over
                // the 44pt minimum at every text size.
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
                .themedFont(.pillLabel, theme: theme)
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
