//
//  Song.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 12/18/24.
//

import SwiftData

@Model
final class Song {
    var title: String
    var location: String                // context in which the song will play
    var populationMin: Int = 0          // minimum population of an area where the song will play
    var populationMax: Int = 1000000000 // maximum population of an area where the song will play -- default overly large
    
    init(title: String, location: String, populationMin: Int?, populationMax: Int?) {
        self.title = title
        self.location = location
        self.populationMin = populationMin ?? self.populationMin // if no value is provided, default to 0
        self.populationMax = populationMax ?? self.populationMax // ""
    }
}


