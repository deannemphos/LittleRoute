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
// @NOTE: these raw values are what gets written into Song.locations, so a
// rename here silently orphans every tag the user has already made. Don't
// touch them without a migration.
enum MusicContext: String {
    case all = "All"
    case gym = "Gyms"
    case restaurant = "Restaurants"
    case store = "Stores"
    case park = "Parks"
    case home = "Home"
    case work = "Work"
    case street = "Streets"
    case driving = "Driving"
    case beach = "Beaches"
    case mountain = "Mountains"
    case city = "Cities"
    case town = "Towns"
    case water = "Water"
    case rainy = "Rainy"       // weather — scores against nearby POIs rather than trumping them
    case snowy = "Snowy"       // weather — scores against nearby POIs rather than trumping them
    case traveling = "Traveling" // fallback when no recognizable POI is nearby, or speed > 35mph
}

// MARK: Presentation
extension MusicContext {

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
