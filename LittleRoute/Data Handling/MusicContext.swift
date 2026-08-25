//
//  MusicContext.swift
//  LittleRoute
//
//  The places the music reacts to. This lives on its own rather than nested
//  inside AudioPlayerManager because it describes a *location*, not playback —
//  the classifier, the detector, the map and the library all need to name one,
//  and none of them should have to reach through the audio player to do it.
//

import SwiftUI

// all contexts the music will account for
//
// @NOTE: the raw value here is the *storage key* and nothing else — the string
// written into Song.locations and into ContextDetector's saved state. It is
// frozen. Renaming one orphans every tag the user has already made, and putting
// that right costs a schema version and a custom migration stage; SongSchemaV4
// is what it looked like the one time it was done, and that stage's map is a
// literal precisely so a later rename can't retroactively break it.
//
// The words a user actually reads are displayName, below. Those are free to
// change whenever somebody prefers "Gym" to "Gyms" — that split is the whole
// point. Adding a case is safe; editing a raw value is not.
//
// Each raw value is written out even though Swift would synthesize the same
// string from the case name. Left to synthesis, renaming `gym` to `fitness`
// would silently move the key too, which is the one edit this whole
// arrangement exists to make impossible to do by accident.
enum MusicContext: String {
    case all = "all"
    case gym = "gym"
    case restaurant = "restaurant"
    case store = "store"
    case park = "park"
    case home = "home"
    case work = "work"
    case street = "street"
    case driving = "driving"
    case beach = "beach"
    case mountain = "mountain"
    case city = "city"
    case town = "town"
    case water = "water"
    case rainy = "rainy"       // weather — scores against nearby POIs rather than trumping them
    case snowy = "snowy"       // weather — scores against nearby POIs rather than trumping them
    case traveling = "traveling" // fallback when no recognizable POI is nearby, or speed > 35mph
}

// MARK: Storage
//
// rawValue under a name that says which of its two former jobs it still has.
// The alias is not ceremony: every call site now reads as either a storage site
// or a display site, and the ones that persist a context are exactly the ones
// that must never drift with the UI. It also leaves one place to change if the
// key ever has to stop being the raw value.
extension MusicContext {

    // What goes on disk. Frozen — see the @NOTE above.
    var storageKey: String { rawValue }

    // Reading a stored tag back. nil means the string on disk names no context
    // we know about, which callers should treat as "leave it alone" rather than
    // "delete it" — an unrecognised tag is inert, and a dropped one is gone.
    init?(storageKey: String) {
        self.init(rawValue: storageKey)
    }
}

// MARK: Presentation
extension MusicContext {

    // What the user reads: chips in the library, the header under the disc, the
    // map's annotations. Safe to reword at any time — nothing persists it.
    //
    // Deliberately no `default:` branch. An exhaustive switch means adding a
    // case fails to compile until it has been given a label, which is the one
    // reminder that arrives on its own; a default would quietly hand the new
    // case somebody else's name.
    var displayName: String {
        switch self {
        case .all: return "All"
        case .gym: return "Gyms"
        case .restaurant: return "Restaurants"
        case .store: return "Stores"
        case .park: return "Parks"
        case .home: return "Home"
        case .work: return "Work"
        case .street: return "Streets"
        case .driving: return "Driving"
        case .beach: return "Beaches"
        case .mountain: return "Mountains"
        case .city: return "Cities"
        case .town: return "Towns"
        case .water: return "Water"
        case .rainy: return "Rainy"
        case .snowy: return "Snowy"
        case .traveling: return "Traveling"
        }
    }

    // Shared context accent color, used for map zones and the main view's
    // background tint.
    var tintColor: Color {
        switch self {
        case .beach: return .cyan
        case .park: return .green
        case .gym: return .orange
        case .restaurant: return .red
        case .store: return .purple
        case .city: return .blue
        case .rainy: return .indigo
        case .snowy: return .mint
        default: return .gray
        }
    }

    // SF Symbol for the map's zone annotations
    var iconName: String {
        switch self {
        case .beach: return "water.waves"
        case .park: return "leaf.fill"
        case .gym: return "figure.run"
        case .restaurant: return "fork.knife"
        case .store: return "bag.fill"
        case .city: return "building.2.fill"
        case .rainy: return "cloud.rain.fill"
        case .snowy: return "snowflake"
        default: return "mappin"
        }
    }
}
