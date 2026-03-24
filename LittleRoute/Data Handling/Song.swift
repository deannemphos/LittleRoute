//
//  Song.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 12/18/24.
//

import SwiftData
import AVFoundation

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
    
    init(title: String, songName: String, artist: String?, locations: [String], populationMin: Int?, populationMax: Int?) {
        self.title = title
        self.songName = songName.replacingOccurrences(of: ".mp3", with: "")
        self.artist = artist
        self.locations = locations
        self.populationMin = populationMin ?? self.populationMin // if no value is provided, default to 0
        self.populationMax = populationMax ?? self.populationMax // ""
    }
    
    // remove class from memory
    deinit {
        // only run this when the user deletes a song
    }
}


