//
//  SilhouetteTheme.swift
//  LittleRoute
//
//  Silhouette visual theme (mockup): one volt-lime ground, ink silhouettes, a
//  white "earbud cord" for anything live. Drawn after the minimalist music ads
//  of the early 2000s: a flat field of one loud colour, a single black shape,
//  a headline that is just a word, and the logo tucked small at the bottom.
//
//  The rules, so later edits don't wander off them:
//    • Exactly three colours: primary (lime), secondary (ink), accent (white).
//      No opacity tints, no gradients. State changes swap between the three.
//    • No drop shadows, no strokes on buttons. Shapes are separated by colour.
//    • Lime is the ground, ink is the shape, white is reserved for the live
//      bits (the play key, the progress bead, glyphs on the transport). Accent never sits directly on lime as text:
//      white-on-lime has no contrast, so white only goes on ink.
//
//  Standalone on purpose. Nothing here references AppTheme, so this file
//  compiles without a `.silhouette` case existing yet; SilhouettePlayerMockup
//  at the bottom renders the whole screen in Xcode Previews with stand-in data.
//  Wiring it in as a real theme is the step after the look is signed off.
//

import SwiftUI

enum Silhouette {
    static let primary   = rgb(0xB8F400)   // volt lime: the ground
    static let secondary = rgb(0x0A0A0A)   // ink: every shape, all text on the ground
    static let accent    = rgb(0xFFFFFF)   // white: the cord, the play key, glyphs on ink

    // 8pt grid. The ads were mostly empty space, so the margins are generous.
    static let margin: CGFloat = 28.0
    static let transportHeight: CGFloat = 56.0
    static let transportInset: CGFloat = 6.0

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Headline

// The context name as an ad headline: one word, very heavy, tight tracking,
// a full stop. It is set as large as it can be and only shrinks when the word
// won't fit ("Restaurants." on an SE), rather than wrapping — a headline that
// breaks mid-word stops reading as a headline.
struct SilhouetteHeadline: View {
    var context: MusicContext
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 64.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Silhouette.secondary)
                    .frame(width: 7, height: 7)
                Text("now playing in")
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityHidden(true)

            Text("\(context.displayName).")
                .font(.system(size: size, weight: .heavy))
                .tracking(-size * 0.05)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel("Current context, \(context.displayName)")
                .accessibilityAddTraits(.isHeader)
                // keyed on the context so a switch re-sets the word rather than
                // morphing one name's glyphs into another's
                .id(context)
                .transition(.push(from: .bottom))
        }
        .foregroundStyle(Silhouette.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: context)
    }
}

// MARK: - Recheck pill

// Ink capsule, white label. The only text button on the screen, so it gets
// the inverted treatment instead of an outline.
struct SilhouettePillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Silhouette.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(Capsule().fill(Silhouette.secondary))
            // a hit target that matches the 44pt minimum without drawing one
            .contentShape(Capsule().inset(by: -6))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Disc

// The silhouette: a solid ink disc with the map set into it. Spin it the same
// way SpinningAlbumView does; nothing here depends on artwork, because the
// whole point of the look is that the shape carries it, not the picture.
struct SilhouetteDisc<Inner: View>: View {
    var diameter: CGFloat
    var innerShare: CGFloat = 0.78
    @ViewBuilder var inner: () -> Inner

    var body: some View {
        ZStack {
            Circle().fill(Silhouette.secondary)
            inner()
                .frame(width: diameter * innerShare, height: diameter * innerShare)
                .clipShape(Circle())
        }
        .frame(width: diameter, height: diameter)
    }
}

// Pushes any map (the real MapKit one included) into the palette. The map is
// forced dark first, so the ground is near-black and the roads come out light;
// grayscale and a hard contrast push turn that into black and white, and the
// lime multiply maps white to lime and leaves black as ink. A two-tone print
// instead of Apple Maps' colours.
//
// Order matters: the colour scheme has to reach the Map before the filters
// read its pixels, which is why the environment write comes first.
struct SilhouetteDuotone: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .grayscale(1.0)
            .contrast(1.8)
            .colorMultiply(Silhouette.primary)
    }
}

extension View {
    func silhouetteDuotone() -> some View { modifier(SilhouetteDuotone()) }
}

// Stand-in map for previews: ink ground, lime streets, white you-are-here.
struct SilhouetteMapPlaceholder: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Silhouette.secondary))

            func street(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                context.stroke(p, with: .color(Silhouette.primary),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            street(CGPoint(x: 0, y: h * 0.31), CGPoint(x: w, y: h * 0.24), 5)
            street(CGPoint(x: 0, y: h * 0.75), CGPoint(x: w, y: h * 0.66), 3)
            street(CGPoint(x: w * 0.29, y: 0), CGPoint(x: w * 0.37, y: h), 3)
            street(CGPoint(x: w * 0.70, y: 0), CGPoint(x: w * 0.66, y: h), 5)
            street(CGPoint(x: 0, y: h * 0.52), CGPoint(x: w, y: h * 0.50), 1.5)
            street(CGPoint(x: w * 0.50, y: 0), CGPoint(x: w * 0.52, y: h), 1.5)

            let park = CGRect(x: w * 0.56, y: h * 0.58, width: w * 0.22, height: h * 0.17)
            context.fill(Path(roundedRect: park, cornerRadius: 10), with: .color(Silhouette.primary))

            let c = CGPoint(x: w * 0.52, y: h * 0.48)
            context.stroke(Path(ellipseIn: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44)),
                           with: .color(Silhouette.accent), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)),
                         with: .color(Silhouette.accent))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Progress (the cord)

// A hairline of ink for the whole song, a heavier ink line for what's been
// played, and an ink bead at the head with a white eye. The white lives on the
// bead rather than on the line: white on lime is 1.3:1 and would vanish.
struct SilhouetteProgress: View {
    var progress: Double
    var currentTime: TimeInterval
    var songLength: TimeInterval

    private var clamped: Double { max(0.0, min(1.0, progress)) }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let x = proxy.size.width * clamped
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Silhouette.secondary)
                        .frame(height: 1)
                    Capsule()
                        .fill(Silhouette.secondary)
                        .frame(width: x, height: 4)
                    Circle()
                        .fill(Silhouette.secondary)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().fill(Silhouette.accent).frame(width: 6, height: 6))
                        .offset(x: x - 8)
                }
                .frame(maxHeight: .infinity)
                .animation(.linear(duration: 0.5), value: clamped)
            }
            .frame(height: 16)

            HStack {
                Text(Self.clock(currentTime))
                Spacer()
                Text("−" + Self.clock(max(0, songLength - currentTime)))
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Silhouette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Self.clock(currentTime)) of \(Self.clock(songLength))")
    }

    static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Transport row

// Shuffle, previous, play/pause and next on one thin ink capsule. One shape,
// not four buttons: the segments are separated by space alone, and play is the
// only one that gets a fill — a white key set into the bar.
//
// Fixed size on purpose, like the other themes' transport: these are hit
// targets, not text. Every segment is at least 44pt tall.
struct SilhouetteTransportBar: View {
    var isPaused: Bool
    var isShuffled: Bool
    var onShuffle: () -> Void
    var onPrevious: () -> Void
    var onPlayPause: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onShuffle) {
                Image(systemName: "shuffle")
            }
            .buttonStyle(SilhouetteSegmentStyle(isOn: isShuffled))
            .accessibilityLabel("Shuffle")
            // on/off is signalled only by the glyph turning lime
            .accessibilityValue(isShuffled ? "On" : "Off")

            Button(action: onPrevious) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(SilhouetteSegmentStyle())
            .accessibilityLabel("Previous song")

            Button(action: onPlayPause) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(SilhouetteSegmentStyle(isKey: true))
            .accessibilityLabel(isPaused ? "Play" : "Pause")

            Button(action: onNext) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(SilhouetteSegmentStyle())
            .accessibilityLabel("Next song")
        }
        .padding(.horizontal, Silhouette.transportInset)
        .frame(height: Silhouette.transportHeight)
        .background(Capsule().fill(Silhouette.secondary))
        .sensoryFeedback(.selection, trigger: isPaused)
        .sensoryFeedback(.selection, trigger: isShuffled)
    }
}

struct SilhouetteSegmentStyle: ButtonStyle {
    var isKey: Bool = false     // the play/pause key: white fill, ink glyph
    var isOn: Bool = false      // a toggle that's engaged: lime glyph

    func makeBody(configuration: Configuration) -> some View {
        let height = Silhouette.transportHeight - 2.0 * Silhouette.transportInset
        return configuration.label
            .font(.system(size: isKey ? 21 : 18, weight: .semibold))
            .foregroundStyle(glyphColor(pressed: configuration.isPressed))
            // the key is wider than its neighbours so it reads as the main action
            .frame(minWidth: isKey ? 96 : 44, maxWidth: .infinity)
            .frame(height: height)
            .background {
                if isKey {
                    Capsule().fill(Silhouette.accent)
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }

    // Pressed swaps to lime rather than fading: there is no fourth colour,
    // and an opacity tint would be one.
    private func glyphColor(pressed: Bool) -> Color {
        if isKey { return Silhouette.secondary }
        return (pressed || isOn) ? Silhouette.primary : Silhouette.accent
    }
}

// MARK: - Top bar glyph

struct SilhouetteGlyph: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Silhouette.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Logo lockup

// Tagline over the wordmark, centred at the foot of the screen, exactly where
// the ads put theirs.
struct SilhouetteLockup: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("Music for wherever you are.")
                .font(.footnote)
            Text("LittleRoute")
                .font(.subheadline.weight(.heavy))
                .tracking(-0.4)
        }
        .foregroundStyle(Silhouette.secondary)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Mockup screen

// The full now-playing screen with stand-in data, for signing off the look in
// Previews before any of it touches ContentView. Layout mirrors ContentView's
// order: top bar, context, disc, progress, transport.
struct SilhouettePlayerMockup: View {
    @State var context: MusicContext = .park
    @State var isPaused = false
    @State var isShuffled = true
    @State var progress = 0.38
    var title = "Golden Hour Bicycle"
    var artist = "The Weekend Lanes"
    var songLength: TimeInterval = 221

    var body: some View {
        GeometryReader { proxy in
            let disc = min(256.0, proxy.size.width - 2.0 * Silhouette.margin - 40.0)

            VStack(spacing: 0) {
                topBar

                VStack(alignment: .leading, spacing: 12) {
                    SilhouetteHeadline(context: context)
                    Button {
                        // contextDetector.refreshNow()
                    } label: {
                        Label("Recheck surroundings", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(SilhouettePillButtonStyle())
                    .accessibilityHint("Rechecks your surroundings and picks music to match.")
                }
                .padding(.horizontal, Silhouette.margin)
                .padding(.top, 20)

                Spacer(minLength: 24)

                SilhouetteDisc(diameter: disc) {
                    SilhouetteMapPlaceholder()
                }

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 0) {
                    SilhouetteProgress(progress: progress,
                                       currentTime: progress * songLength,
                                       songLength: songLength)
                    Text(title)
                        .font(.title2.weight(.bold))
                        .tracking(-0.8)
                        .lineLimit(2)
                        .padding(.top, 22)
                    Text(artist)
                        .font(.body)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
                .foregroundStyle(Silhouette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Silhouette.margin)

                SilhouetteTransportBar(
                    isPaused: isPaused,
                    isShuffled: isShuffled,
                    onShuffle: { isShuffled.toggle() },
                    onPrevious: { progress = 0 },
                    onPlayPause: { isPaused.toggle() },
                    onNext: { progress = 0 }
                )
                .padding(.horizontal, 20)
                .padding(.top, 28)

                Spacer(minLength: 20)

                SilhouetteLockup()
                    .padding(.bottom, 12)
            }
        }
        .background(Silhouette.primary.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Image(systemName: "music.note.list").modifier(SilhouetteGlyph())
                .accessibilityLabel("Music library")
            Image(systemName: "plus.circle").modifier(SilhouetteGlyph())
                .accessibilityLabel("Import songs")
            Spacer()
            Image(systemName: "paintbrush.fill").modifier(SilhouetteGlyph())
                .accessibilityLabel("Change theme")
        }
        .padding(.horizontal, 16)
    }
}

#Preview("Silhouette · playing") {
    SilhouettePlayerMockup()
}

#Preview("Silhouette · paused, long context") {
    SilhouettePlayerMockup(
        context: .restaurant,
        isPaused: true,
        isShuffled: false,
        progress: 0.72,
        title: "Table for Two, Window Seat",
        artist: "Mono Supper Club"
    )
}

#Preview("Transport bar") {
    @Previewable @State var paused = false
    @Previewable @State var shuffled = false
    SilhouetteTransportBar(
        isPaused: paused, isShuffled: shuffled,
        onShuffle: { shuffled.toggle() }, onPrevious: {},
        onPlayPause: { paused.toggle() }, onNext: {}
    )
    .padding(20)
    .background(Silhouette.primary)
}
