//
//  Song.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 12/18/24.
//

import SwiftData
import AVFoundation

// The live model, and what SongSchemaV2 points at. Its shape *is* the current
// store, so changing anything stored below needs a new schema version and a
// migration stage — and V2 has to be frozen first, or it stops describing the
// store people already have. See SongSchema.swift.
@Model
final class Song {
    var title: String
    var songName: String /* {
        // This is the actual file name of the song, without the extension
        return title.replacingOccurrences(of: ".mp3", with: "")
    } */
    var artist: String? = nil // optional artist name
    // @TODO: set possible locations to an enum
    var locations: [String]                // context in which the song will play
    // @TODO: set population min/max to be dependent on location automatically
    var populationMin: Int = 0          // minimum population of an area where the song will play
    var populationMax: Int = 1000000000 // maximum population of an area where the song will play -- default overly large

    // Whether this song's mp3 was imported by the user into Documents/Music, as
    // opposed to shipping inside the app bundle. LibraryView shows exactly the
    // imported ones, and used to work that out by asking the filesystem — one
    // fileExists per song, on the main thread, every time the List re-evaluated
    // its body. Both insert paths in AudioPlayerManager set this now instead.
    //
    // Defaulted rather than optional: a default is what makes the column
    // inferable as a lightweight change, and false is the harmless answer for a
    // row nobody set. It keeps a song off the library screen, where the worst
    // case is a song the user can't retag; true would put a bundled song there
    // and offer a swipe that deletes a file we don't own. Rows written before
    // the flag existed are backfilled from the filesystem by the V2 → V3 stage
    // in SongSchema.swift.
    var isImported: Bool = false

    // isImported defaults here too, so the callers that predate it — the addSong
    // stub below, the test fixtures — keep compiling. The two paths that
    // actually matter pass it explicitly; see AudioPlayerManager.
    init(title: String, songName: String, artist: String?, locations: [String], populationMin: Int?, populationMax: Int?, isImported: Bool = false) {
        self.title = title
        self.songName = songName.replacingOccurrences(of: ".mp3", with: "")
        self.artist = artist
        self.locations = locations
        self.populationMin = populationMin ?? self.populationMin // if no value is provided, default to 0
        self.populationMax = populationMax ?? self.populationMax // ""
        self.isImported = isImported
    }
    
    // remove class from memory
    deinit {
        // only run this when the user deletes a song
    }
}


