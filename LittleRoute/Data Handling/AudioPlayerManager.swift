//
//  AudioPlayerManager.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 5/7/25.
//

import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import _SwiftData_SwiftUI

// Everything on this class expects to be called from the main thread. It writes
// @Published state that SwiftUI reads there, and it schedules its progress Timer on
// whatever run loop the caller happens to be on. Every Swift caller is view code, so
// they already satisfy that. The three ways in from outside Swift can't promise it —
// the AVAudioPlayerDelegate callback, the AVAudioSession notification selectors, and
// the MPRemoteCommandCenter blocks all arrive on a thread of the system's choosing —
// so each of those hops onto main itself before touching anything here.
class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    @Published var isPaused: Bool = false
    @Published var isShuffled: Bool = false
    @Published var songLength: TimeInterval = 0.0   // total length of the song
    @Published var currentTime: TimeInterval = 0.0  // current playback time
    @Published var currentContext: MusicContext = .all
    @Published var currentSong: Song? = nil // the currently playing song, if any

    @Published private(set) var songQueue: [Song] = [] // read-only outside; UI observes this for the queue drawer

    private var audioPlayer: AVAudioPlayer?
    private var currentIndex: Int = 0 // index of the current song in the queue
    private var playbackTimer: Timer?
    private var ticksSinceNowPlayingSync = 0 // see startPlaybackTimer
    private var wasPlayingBeforeInterruption = false // see handleInterruption
    private var hasActivatedSession = false // see activateSession / deactivateSession

    // 0.5s per playback tick, so the lock screen's elapsed time is reconciled every 5 seconds
    private static let nowPlayingSyncTicks = 10

    static let shared = AudioPlayerManager()

    private override init() {
        super.init()
        configureAudioSession()
        observeAudioSessionEvents()
        setupRemoteCommands()
    }

    // Configure the shared audio session for background playback.
    // Requires the "audio" UIBackgroundMode (declared in Info.plist).
    //
    // Category only, deliberately. Activating the session is the act that silences
    // whatever else the device is playing, and this runs from the singleton's init —
    // which the first view to so much as read AudioPlayerManager.shared triggers, long
    // before the user has asked for a note of music. So simply opening LittleRoute used
    // to cut off someone's podcast. Declaring the category takes nothing from anyone; it
    // only tells iOS what kind of app we are. The session itself is taken in
    // activateSession, on the way into actual playback.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    // Take the audio session, immediately before we make a sound. Every path into
    // playback goes through here.
    //
    // Called ahead of every play(), including the repeated ones, rather than only the
    // first: activating an already-active session is a no-op, and that is far safer than
    // keeping a Bool that claims we are active and being wrong. iOS deactivates us
    // without asking — for interruptions, and for a media services reset — and a stale
    // "already active" in that direction would mean silently never taking the session
    // back, i.e. a player that looks like it is playing and makes no sound.
    //
    // Returns whether we got it, so callers can leave isPaused honest if we didn't.
    private func activateSession() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            hasActivatedSession = true
            return true
        } catch {
            print("Failed to activate audio session: \(error)")
            return false
        }
    }

    // Hand the session back, and tell whatever we interrupted that it can pick up again.
    //
    // Called from exactly one place — the empty-queue teardown in reloadQueue, where
    // there is genuinely nothing left to play. Everywhere else that playback stops, we
    // keep it:
    //
    //   - Not on pause. A paused music app is still the app that owns the session; that
    //     is what keeps the lock-screen play button live. Giving the session up for a
    //     two-second pause invites another app to take it, and we may not get it back.
    //   - Not on an interruption. iOS has already deactivated us by the time .began
    //     arrives, and telling other apps to resume mid-call is the exact opposite of
    //     what the .shouldResume path below is trying to do.
    //   - Not on backgrounding. Surviving the screen locking is the entire point of the
    //     audio background mode.
    //
    // The flag only ever gates deactivation, never activation — being wrong here costs a
    // redundant call, whereas being wrong the other way costs silence.
    private func deactivateSession() {
        guard hasActivatedSession else { return }
        hasActivatedSession = false

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }

    // MARK: Audio Session Interruptions & Route Changes
    // Phone calls, Siri, and other apps grabbing the session all arrive as interruption
    // notifications; unplugging headphones arrives as a route change. In both cases iOS
    // has already silenced us, so with nobody listening isPaused keeps insisting we're
    // playing and the UI shows a pause button for silence.
    //
    // We deliberately never remove these observers. This class is a singleton reached
    // through .shared, so it lives as long as the process and deinit is unreachable —
    // "removing" them would only mean going deaf to interruptions for the rest of the
    // app's life. (NotificationCenter has held zeroing weak references to selector-based
    // observers since iOS 9, so there is nothing to dangle either way.)
    private func observeAudioSessionEvents() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        center.addObserver(self,
                           selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification,
                           object: session)
        center.addObserver(self,
                           selector: #selector(handleRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification,
                           object: session)
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        // Unpack everything we need up front so only plain values cross onto the main
        // queue below, rather than the notification's untyped userInfo dictionary.
        let shouldResume: Bool
        if let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt {
            shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
        } else {
            shouldResume = false
        }

        // These land on whatever thread the audio session feels like using, and
        // everything below touches @Published state and a run-loop Timer.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch type {
            case .began:
                // Ask our own state, not the player's: by the time .began is delivered
                // iOS may already have paused it, and isPlaying would then be false —
                // which would make us decide we were never playing and never resume.
                // isPaused reflects what the user actually asked for.
                self.wasPlayingBeforeInterruption = !self.isPaused && self.audioPlayer != nil
                self.pauseForSystemEvent(reason: "interrupted")

            case .ended:
                // Only pick up where we left off if we were genuinely playing when we
                // got cut off, otherwise a call would start music the user had paused.
                guard self.wasPlayingBeforeInterruption else { return }
                self.wasPlayingBeforeInterruption = false

                guard shouldResume else { return }
                self.resumeAfterInterruption()

            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }

        // .oldDeviceUnavailable is headphones being yanked or a Bluetooth device walking
        // away. iOS falls back to the built-in speaker, and it's the one route change
        // where carrying on playing would be actively rude. Every other reason — a new
        // device appearing, a category change — we let play through untouched.
        guard reason == .oldDeviceUnavailable else { return }

        DispatchQueue.main.async { [weak self] in
            self?.pauseForSystemEvent(reason: "audio route went away")
        }
    }

    // Shared by both paths above: by the time either fires the system has already
    // silenced us, so the job here is purely to stop lying about it.
    private func pauseForSystemEvent(reason: String) {
        // There may be no player at all — reloadQueue tears it down when a context
        // leaves nothing to play, so the song on screen a moment ago can be gone.
        // Nothing to pause in that case, but isPaused still has to say so.
        audioPlayer?.pause()
        isPaused = true
        stopPlaybackTimer()
        updateNowPlayingInfo()
        print("Playback paused: \(reason)")
    }

    private func resumeAfterInterruption() {
        guard let player = audioPlayer else {
            // The queue was rebuilt out from under us while the call was going on and
            // there's nothing loaded any more. Stay paused rather than pretend.
            isPaused = true
            updateNowPlayingInfo()
            print("Interruption ended, but there is no loaded song to resume")
            return
        }

        // Our session was deactivated for the duration of the interruption, so it has
        // to be reactivated before the player will make any sound again. Same door as
        // every other entry into playback — this is not a special case, it just happens
        // to be the one where we know for certain the session is gone.
        guard activateSession() else {
            print("Interruption ended, but the audio session would not come back")
            isPaused = true
            updateNowPlayingInfo()
            return
        }

        player.play()
        isPaused = false
        startPlaybackTimer()
        updateNowPlayingInfo()
        print("Interruption ended, resuming playback")
    }

    // Lock screen / Control Center playback controls.
    //
    // MediaPlayer runs these blocks on a thread of its own choosing, and everything they
    // reach — musicPlayPause, skip, previous — rewrites @Published state, so each one
    // hops onto main before it touches anything, the same way the interruption handlers
    // above do.
    //
    // The reads hop too, not just the writes: play and pause decide what to do by asking
    // isPaused, and asking from another thread races with the main-thread write just as
    // badly as writing would. The price of moving that check onto main is that we have to
    // answer the system before we know the answer, so these can no longer report
    // .commandFailed for "we were already playing". Reporting .success and quietly doing
    // nothing is the better lie of the two — a redundant play command isn't a failure.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            DispatchQueue.main.async {
                guard self.isPaused else { return }
                self.musicPlayPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            DispatchQueue.main.async {
                guard !self.isPaused else { return }
                self.musicPlayPause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.musicPlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skip() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
    }

    // Publish current song metadata to the lock screen / Control Center
    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentSong?.title ?? "LittleRoute"
        info[MPMediaItemPropertyArtist] = currentSong?.artist ?? "Unknown Artist"
        info[MPMediaItemPropertyPlaybackDuration] = songLength
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer?.currentTime ?? 0.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // Computed property for progress (0.0 to 1.0)
    var progress: Double {
        guard songLength > 0 else { return 0.0 }
        return currentTime / songLength
    }
    
    // Load songs from the Music folder in the app bundle
    public func loadSongsFromBundle(modelContext: ModelContext) -> [Song] {
        guard let musicPath = Bundle.main.resourcePath?.appending("/Music") else {
            print("Music folder not found")
            return []
        }
        
        var loadedSongs: [Song] = []
        
        do {
            let fileManager = FileManager.default
            let files = try fileManager.contentsOfDirectory(atPath: musicPath)
            let mp3Files = files.filter { $0.hasSuffix(".mp3") }
            
            for fileName in mp3Files {
                let songName = fileName.replacingOccurrences(of: ".mp3", with: "")
                let title = songName // Use filename as title
                
                // Check if song already exists
                let descriptor = FetchDescriptor<Song>(predicate: #Predicate { $0.songName == songName })
                let existingSongs = try? modelContext.fetch(descriptor)
                
                if let existing = existingSongs?.first {
                    loadedSongs.append(existing)
                } else {
                    let newSong = Song(title: title, songName: songName, artist: "Unknown Artist", locations: ["All"], populationMin: 0, populationMax: 10000000)
                    modelContext.insert(newSong)
                    loadedSongs.append(newSong)
                }
            }
            
            try? modelContext.save()
            print("Loaded \(mp3Files.count) songs from Music folder")
        } catch {
            print("Error loading songs: \(error)")
        }
        
        return loadedSongs
    }
    
    // MARK: Song File Locations
    // Directory where user-imported mp3s are stored (Documents/Music)
    static var importedMusicDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    // Resolve a song file by name: bundled Music folder first, then imported files
    static func url(forSongFile songName: String) -> URL? {
        if let path = Bundle.main.path(forResource: songName, ofType: "mp3", inDirectory: "Music") {
            return URL(fileURLWithPath: path)
        }
        let imported = importedMusicDirectory.appendingPathComponent("\(songName).mp3")
        return FileManager.default.fileExists(atPath: imported.path) ? imported : nil
    }

    // Import user-selected mp3 files: copy into Documents/Music, read ID3
    // title/artist when available, and insert new Song records.
    @MainActor
    public func importSongs(from urls: [URL], modelContext: ModelContext) async {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let songName = url.deletingPathExtension().lastPathComponent
            let destination = Self.importedMusicDirectory.appendingPathComponent("\(songName).mp3")

            // Copy the file in (even if a Song record already exists from a
            // previous failed attempt, the file may be missing)
            if !FileManager.default.fileExists(atPath: destination.path) || !songExists(songName, in: modelContext) {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Self.coordinatedCopy(from: url, to: destination)
                    }.value
                } catch {
                    print("Failed to copy imported song '\(songName)': \(error)")
                    continue
                }
            }

            // Skip the record insert for duplicates
            if songExists(songName, in: modelContext) {
                print("Song already exists, skipping record: \(songName)")
                continue
            }

            // Pull title/artist from ID3 tags, falling back to the filename
            var title = songName
            var artist = "Unknown Artist"
            let asset = AVURLAsset(url: destination)
            if let metadata = try? await asset.load(.commonMetadata) {
                if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first,
                   let value = try? await item.load(.stringValue) {
                    title = value
                }
                if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first,
                   let value = try? await item.load(.stringValue) {
                    artist = value
                }
            }

            let newSong = Song(title: title, songName: songName, artist: artist, locations: ["All"], populationMin: 0, populationMax: 10000000)
            modelContext.insert(newSong)
            print("Imported song: \(title)")
        }

        do {
            try modelContext.save()
        } catch {
            print("Failed to save imported songs: \(error)")
        }

        // Refresh the queue so new songs are playable immediately
        let allSongs = (try? modelContext.fetch(FetchDescriptor<Song>())) ?? []
        reloadQueue(newContext: currentContext, shuffle: isShuffled, songs: allSongs)
    }

    private func songExists(_ songName: String, in modelContext: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Song>(predicate: #Predicate { $0.songName == songName })
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    // File-coordinated copy. The .forUploading option materializes files that
    // aren't locally available yet (e.g. iCloud Drive items) before copying.
    private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?

        NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading, error: &coordinatorError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let error = coordinatorError { throw error }
        if let error = copyError { throw error }
    }

    // MARK: Audio Playback Functions
    // Start playing on launch, but only if the user isn't already listening to
    // something else.
    //
    // Opening LittleRoute used to stop whatever was playing — a podcast, another
    // music app — because .onAppear called musicPlayPause() unconditionally, and
    // taking the session is what silences the other app. Making activation lazy
    // (see activateSession) didn't help on its own, since we asked for playback a
    // frame after launch anyway.
    //
    // isOtherAudioPlaying answers "is someone else making noise right now", which
    // is exactly the question. If they are, we stay quiet and wait to be asked.
    public func startPlaybackIfNothingElseIsPlaying() {
        guard !songQueue.isEmpty else { return }

        guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else {
            print("Something else is playing — starting paused rather than interrupting it")
            return
        }

        guard isPaused || audioPlayer == nil else { return } // already going, nothing to do
        musicPlayPause()
    }

    // Play the music if not paused, pause the music if paused. ezpz
    public func musicPlayPause() {
        // If no audio is loaded and we have songs in queue, load the first one
        if audioPlayer == nil && !songQueue.isEmpty {
            currentSong = songQueue[currentIndex]
            loadAudio(fileName: songQueue[currentIndex].songName)
        }
        
        if audioPlayer != nil && audioPlayer!.isPlaying {
            audioPlayer!.pause()
            isPaused = true
            stopPlaybackTimer()
        }
        else if audioPlayer != nil && !audioPlayer!.isPlaying {
            // this is usually the first time anyone has asked for sound, so it's where
            // the session actually gets taken — see activateSession
            if activateSession() {
                audioPlayer!.play()
                isPaused = false
                startPlaybackTimer()
            } else {
                // no session, no sound. Say so rather than showing a pause button
                // over silence.
                isPaused = true
                stopPlaybackTimer()
            }
        }
        
        updateNowPlayingInfo()
        print("Audio Player is now \(isPaused ? "paused" : "playing")")
    }
    
    // Start whatever loadAudio just prepared. skip / previous / play(song:) all do the
    // same thing once the file is loaded, and all three need the session in hand before
    // the player will be audible, so the sequence lives here instead of in each of them.
    private func playLoadedSong() {
        guard activateSession() else {
            isPaused = true
            stopPlaybackTimer()
            updateNowPlayingInfo()
            return
        }

        audioPlayer?.play()
        isPaused = false
        startPlaybackTimer()
        updateNowPlayingInfo()
    }

    public func skip() {
        guard !songQueue.isEmpty else {
            print("No songs in queue")
            return
        }
        
        // Set the current index to the next song in the queue
        // if on the last song, loop back to the start of the queue
        currentIndex = (currentIndex + 1) % songQueue.count
        currentSong = songQueue[currentIndex]
        let nextSong = songQueue[currentIndex].songName
        
        loadAudio(fileName: nextSong)
        playLoadedSong()
    }
    
    // Jump to a specific song already in the queue and play it
    public func play(song: Song) {
        guard let index = songQueue.firstIndex(where: { $0.songName == song.songName }) else {
            print("Song not in queue: \(song.songName)")
            return
        }

        currentIndex = index
        currentSong = songQueue[currentIndex]
        loadAudio(fileName: songQueue[currentIndex].songName)
        playLoadedSong()
    }

    public func previous() {
        guard !songQueue.isEmpty else {
            print("No songs in queue")
            return
        }
        
        // Same as the skip function but in reverse
        currentIndex = (currentIndex - 1 + songQueue.count) % songQueue.count
        currentSong = songQueue[currentIndex]
        let previousSong = songQueue[currentIndex].songName
        
        loadAudio(fileName: previousSong)
        playLoadedSong()
    }

    // Toggle shuffle mode
    // Technically we can just call reloadQueue instead of this but it'll save an unnecessary full list reset
    // and slightly reduce lag if the user reshuffles
    public func toggleShuffle() {
        isShuffled.toggle()
        
        if(isShuffled) {
            songQueue.shuffle()
        } else {
            reloadQueue(newContext: currentContext, shuffle: isShuffled, songs: songQueue)
        }
    }

    // Prepare the audio player with the selected song
    private func loadAudio(fileName: String) {
        
        guard let url = Self.url(forSongFile: fileName) else {
            print("Could not find file: \(fileName).mp3")
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            songLength = audioPlayer?.duration ?? 0.0
            currentTime = 0.0
        } catch {
            print("Could not create audio player: \(error)")
        }
    }
    
    // MARK: AVAudioPlayerDelegate
    // Automatically play the next song when the current one finishes.
    //
    // AVFoundation delivers this on the thread running the player's own audio queue, not
    // necessarily main, and skip() rewrites @Published state and reschedules the playback
    // Timer. Hopping also means this callback has returned before skip() swaps audioPlayer
    // out, rather than us releasing the player from inside its own delegate method.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("Song finished, playing next song")
            self.skip()
        }
    }
    
    // MARK: Song Database Functions
    // Insert a new song
    // @TODO: Add field for uploading .mp3 files
    // @TODO: figure out how to handle the population detection issue
    public func addSong(title: String, artist: String, modelContext: ModelContext) {
        let newSong = Song(title: title, songName: "filename", artist: artist, locations: ["location"], populationMin: 0, populationMax: 9999)
        modelContext.insert(newSong)
        try? modelContext.save()
    }

    // Remove an existing song
    private func removeSong(_ song: Song, modelContext: ModelContext) {
        modelContext.delete(song)
        try? modelContext.save()
    }
    
    // Switch to a new context with a short crossfade.
    // Called when the user enters a new area (via ContextDetector).
    public func switchContext(to newContext: MusicContext, songs: [Song], fadeDuration: TimeInterval = 1.5) {
        guard newContext != currentContext else { return }

        currentContext = newContext
        let wasPlaying = audioPlayer?.isPlaying ?? false

        guard wasPlaying, let player = audioPlayer else {
            // Nothing audible — just swap the queue silently, no auto-play
            reloadQueue(newContext: newContext, shuffle: isShuffled, songs: songs)
            return
        }

        // Fade out the old song, then load the new queue and fade the next song in
        player.setVolume(0.0, fadeDuration: fadeDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration) { [weak self] in
            guard let self = self else { return }
            self.audioPlayer?.stop() // ensure the faded-out song doesn't keep playing if the new queue is empty
            // we've already faded this song out and stopped it, so we do want a fresh
            // track to fade in even if the old one also fits the new context
            self.reloadQueue(newContext: newContext, shuffle: self.isShuffled, songs: songs, keepCurrentSong: false)

            guard let newPlayer = self.audioPlayer, self.currentSong != nil else { return }

            // We only get here off the back of something that was already audible, so
            // the session is normally still ours — but this is a play() like any other
            // and the fade-in would be a silent one if it weren't.
            guard self.activateSession() else {
                self.isPaused = true
                self.updateNowPlayingInfo()
                return
            }

            newPlayer.volume = 0.0
            newPlayer.play()
            newPlayer.setVolume(1.0, fadeDuration: fadeDuration)
            self.isPaused = false
            self.startPlaybackTimer()
            self.updateNowPlayingInfo()
        }
    }

    // Reset the queue upon entering a new location/context.
    // keepCurrentSong defaults to true because most callers — a tag toggle, an import,
    // a delete — are editing the library underneath a song that is happily playing, and
    // rebuilding the queue should not yank the player out from under it. Only pass false
    // when the caller genuinely wants to move to a different track.
    public func reloadQueue(newContext: MusicContext, shuffle: Bool, songs: [Song], keepCurrentSong: Bool = true) {

        // add only the new songs to the queue
        songQueue = songs.filter { $0.locations.contains(newContext.rawValue) }

        // shuffle if user has the option toggled
        if isShuffled {
            songQueue.shuffle()
        }

        // Nothing matches any more, so there is no song left to keep. Tear the player
        // down instead of leaving a stale currentSong playing a track the queue no
        // longer contains — otherwise the UI reports a song that isn't in the drawer.
        guard !songQueue.isEmpty else {
            print("No songs matched the current context")
            currentIndex = 0
            currentSong = nil
            stopPlaybackTimer()
            audioPlayer?.stop()
            audioPlayer = nil

            // The one place we genuinely stop rather than pause: no player, no queue,
            // nothing for the user to press play on. Hand the session back so whatever
            // we interrupted on the way in can carry on.
            deactivateSession()
            // and drop any pending "resume when the call ends" intent along with it —
            // we just told the rest of the device we were finished.
            wasPlayingBeforeInterruption = false

            isPaused = true
            songLength = 0.0
            currentTime = 0.0
            updateNowPlayingInfo()
            return
        }

        // If the song that's playing survived the rebuild, just follow it to its new
        // index and leave audioPlayer alone. Calling loadAudio here would construct a
        // fresh AVAudioPlayer and deallocate the one mid-song, which is why toggling a
        // single context chip used to stop the music.
        if keepCurrentSong,
           let playing = currentSong,
           let index = songQueue.firstIndex(where: { $0.songName == playing.songName }) {
            currentIndex = index
            print("Queue reloaded with \(songQueue.count) songs, still playing \(playing.songName)")
            return
        }

        // Otherwise start at the top of the new queue, but don't auto-play
        currentIndex = 0
        currentSong = songQueue[currentIndex]
        loadAudio(fileName: songQueue[currentIndex].songName)
        print("Queue loaded with \(songQueue.count) songs")
    }
    
    // Timer management for playback progress.
    // scheduledTimer attaches to the *calling* thread's run loop, so this relies on the
    // main-thread contract at the top of the file for more than just the currentTime
    // write below: scheduled from a background thread it would land on a run loop nobody
    // is running, and the progress bar would simply stop moving. That was reachable until
    // the remote commands started hopping — a skip from the lock screen froze the scrubber.
    private func startPlaybackTimer() {
        stopPlaybackTimer()
        // every caller of this has just pushed now-playing info itself, so start the
        // reconciliation interval fresh rather than firing again on the next tick
        ticksSinceNowPlayingSync = 0
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.currentTime = player.currentTime
            if !player.isPlaying {
                self.stopPlaybackTimer()
                return
            }

            // The lock screen works out elapsed time from the last value we handed it
            // plus the playback rate, so left alone the Control Center scrubber slowly
            // drifts away from where the song actually is. Pushing on every tick would
            // fix that, but it means handing the whole dictionary to the media server
            // twice a second — far more chatter than a scrubber is worth. Reconciling
            // every few seconds is close enough that nobody can see the difference.
            self.ticksSinceNowPlayingSync += 1
            if self.ticksSinceNowPlayingSync >= Self.nowPlayingSyncTicks {
                self.ticksSinceNowPlayingSync = 0
                self.updateNowPlayingInfo()
            }
        }
    }
    
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}
