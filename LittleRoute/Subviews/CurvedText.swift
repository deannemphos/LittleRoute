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

    // What VoiceOver should say instead of the letters. The *collapsing* below is
    // unconditional because the letter-per-Text split is this view's own doing —
    // no caller should have to remember to undo it. The wording, though, is
    // caller knowledge: only the screen placing the arc knows whether it's a
    // title or an artist, so that part comes in as a parameter. Defaults to the
    // raw string, which is already correct, just undifferentiated.
    var spokenLabel: String? = nil

    // Reads the user's text-size setting back as a plain multiplier: at the
    // default size the probe comes through untouched, so probe / base is the
    // factor. A probe rather than a scaled font size directly, because the
    // factor has to be clamped (see Metrics.maxScale) and the same clamp has to
    // be available to whoever reserves screen room for the arc.
    @ScaledMetric(relativeTo: .caption) private var scaleProbe: CGFloat = CurvedText.Metrics.probeBase

    private var scaledFontSize: CGFloat {
        fontSize * Metrics.scale(fromProbe: scaleProbe)
    }

    var body: some View {
        // one size drives both the glyphs and the angles they sit at, so they
        // can't disagree the way they did when the geometry assumed a fixed 14pt
        let size = scaledFontSize
        let anglePerChar = Metrics.anglePerChar(fontSize: size, radius: radius)
        let chars = Metrics.fitted(text, anglePerChar: anglePerChar)
        let total = anglePerChar * Double(chars.count)

        ZStack {
            ForEach(chars.indices, id: \.self) { index in
                // angle of this char, centered around the top (0 = straight up)
                let angle = -total / 2 + anglePerChar * (Double(index) + 0.5)
                Text(String(chars[index]))
                    // scaled by hand above, so a fixed font here on purpose:
                    // routing this through .scaledFont would apply the user's
                    // setting a second time and the glyphs would drift out of
                    // step with the angles they were laid out at
                    .font(.system(size: size, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .offset(y: -radius)
                    .rotationEffect(.radians(angle))
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        // one Text per character means VoiceOver otherwise spells the song out
        // letter by letter. Collapse the whole arc into a single element and
        // speak the phrase instead.
        //
        // Note this deliberately labels from `text`, not from `chars` — the arc
        // may have been trimmed to fit the circle, but there is no reason to
        // trim what gets spoken, and a truncated title read aloud would be a
        // regression on the visual one rather than a match for it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel ?? text)
    }
}

// MARK: - Arc metrics

// Kept alongside the view that draws the arc, but deliberately reachable from
// outside it: "will this arc fit on screen" is a question about how far past
// `radius` the glyphs actually paint, and only this file knows that. ContentView
// sizes the album disc from these so the two can't fall out of agreement.
extension CurvedText {
    enum Metrics {
        // @ScaledMetric probe base. 100 rather than 1 so the factor survives any
        // rounding UIFontMetrics does on the way out.
        static let probeBase: CGFloat = 100.0

        // How far the user's text setting is allowed to push arc type.
        //
        // Flat text can grow three or four times over and just reflow. An arc
        // can't: the circle it rides is bounded by the screen, so every extra
        // point of size widens each letter *and* eats into the radius that has
        // to hold them. Past roughly 1.6x more of the title is lost to
        // truncation than is gained in legibility, so that is where growth
        // stops and trimming starts. VoiceOver still gets the whole string.
        static let maxScale: CGFloat = 1.6

        // No shrinking below 1.0 either — this is already the smallest type in
        // the app and there is nothing to gain by making it smaller still.
        static func scale(fromProbe probe: CGFloat) -> CGFloat {
            min(max(probe / probeBase, 1.0), maxScale)
        }

        // Letters stay in the top half of the disc. Past ±90° they are lying on
        // their sides and heading down into the map and the transport controls.
        static let maxArc: Double = .pi

        // Average angular width of one character at this radius, in radians.
        // 0.62 is the rough advance-to-size ratio of the rounded heavy face —
        // still an approximation, but now taken against the size actually being
        // rendered rather than against a base size the text setting has moved.
        static func anglePerChar(fontSize: CGFloat, radius: CGFloat) -> Double {
            guard radius > 0.0 else { return 0.0 }
            return Double(fontSize * 0.62 / radius)
        }

        // A glyph is centred on `radius`, so it paints roughly half a line height
        // to either side of the arc. This is the outward half — the number that
        // decides whether the arc clears the edge of the screen, and the reason
        // the old layout ran off an SE even before Dynamic Type entered into it.
        static func glyphOverhang(fontSize: CGFloat) -> CGFloat {
            fontSize * 0.75
        }

        // Trim to what fits inside maxArc, with an ellipsis so a long title reads
        // as cut short rather than as the wrong title.
        static func fitted(_ source: String, anglePerChar: Double) -> [Character] {
            let all = Array(source)
            guard anglePerChar > 0.0 else { return all }
            // the ceiling is only here so a pathologically small angle can't
            // overflow the Int conversion; nothing real gets near it
            let capacity = Int(min(maxArc / anglePerChar, 512.0))
            guard capacity < all.count else { return all }
            guard capacity > 1 else { return Array(all.prefix(max(capacity, 0))) }
            let ellipsis: Character = "…"
            return Array(all.prefix(capacity - 1)) + [ellipsis]
        }
    }
}
