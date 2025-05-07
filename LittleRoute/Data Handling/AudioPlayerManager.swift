//
//  AudioPlayerManager.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 5/7/25.
//

import Foundation
import AVFoundation

class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying: Bool = false
    @Published var currentSong: Song?
    
    private var audioPlayer: AVAudioPlayer?
    
    static let shared = AudioPlayerManager()
}
