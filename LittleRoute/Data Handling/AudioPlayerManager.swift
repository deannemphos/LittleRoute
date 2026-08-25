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
import Observation
import _SwiftData_SwiftUI

// Everything on this class expects to be called from the main thread. It writes
// observable state that SwiftUI reads there, and it schedules its progress Timer on
// whatever run loop the caller happens to be on. Every Swift caller is view code, so
// they already satisfy that. The three ways in from outside Swift can't promise it —
// the AVAudioPlayerDelegate callback, the AVAudioSession notification selectors, and
// the MPRemoteCommandCenter blocks all arrive on a thread of the system's choosing —
// so each of those hops onto main itself before touching anything here.
//
// MARK: Strict concurrency, and why the obvious annotation is missing
//
// This file holds most of the hops in the app and is the obvious candidate for
// @MainActor. It deliberately does not carry it. Under targeted checking every
// DispatchQueue.main.async below captures a self that is not Sendable inside a
// @Sendable closure, and every one of them is reported. Those reports are all the
// same report, and it is a report about an annotation that is missing rather than
// about the hops, which are correct as written.
//
// What the annotation would actually cost, in the order it bites:
//
//   1. It does not silence the hops. It inverts them. A DispatchQueue.main.async
//      block is a nonisolated closure no matter which actor the enclosing type
//      belongs to, so `self.skip()` inside one stops being a non-Sendable capture
//      and starts being a call to a main-actor method from a nonisolated context —
//      an error where there was a warning. Each of the eight bodies would need
//      MainActor.assumeIsolated around it. That is the right spelling, and we have
//      genuinely just hopped so it would hold, but it is eight more places to get
//      right with nothing to check the work.
//
//   2. The six doors from outside Swift would have to be marked nonisolated and
//      keep their hops regardless. Actor isolation is not enforced across the ObjC
//      runtime: audioPlayerDidFinishPlaying, the two #selector handlers, and the
//      three MPRemoteCommandCenter blocks are called by AVFoundation,
//      NotificationCenter and MediaPlayer on threads of their own choosing, and
//      @MainActor would only make the compiler *believe* they arrive on main. The
//      hop is the guarantee; the annotation is a claim about it. Deleting a hop
//      because "the class is @MainActor now" is the one edit here that converts a
//      warning into a real crash — and it is precisely the edit the annotation
//      invites, which is the reason this paragraph is longer than the others.
//
//   3. coordinatedCopy would need a nonisolated of its own. importSongs runs it
//      inside a Task.detached, and a main-actor static is not callable from there.
//
//   4. `shared` becomes main-actor isolated, and both ContentView and LibraryView
//      read it from a stored-property initialiser — `private let audioManager =
//      AudioPlayerManager.shared` — which is not a main-actor context unless the
//      View conformance makes it one. Whether it does is the part that cannot be
//      settled by reading: SwiftUI declares View as @MainActor @preconcurrency, so
//      the isolation may already be inferred onto both structs and the question may
//      be moot; or it may want @MainActor spelled out on them; or nonisolated(unsafe)
//      on `shared`. Three plausible answers, and the only thing that can pick
//      between them is a compiler.
//
// So: no annotation, the hops stay exactly as they are, and the warnings stand with
// this note attached to them. A warning nobody wrote down is a warning the next
// person investigates from scratch. This one has been investigated, and the finding
// is that silencing it blind costs more than carrying it.
//
// One likely diagnostic in this file is not about the hops at all. `shared` is
// static storage of a non-Sendable type, which complete mode certainly objects to
// and targeted mode may. If it does, the fix is one word — `nonisolated(unsafe)
// static let shared` — and it is an honest word here rather than a silencing one:
// the reference itself is immutable, and what it points at is protected by the
// main-thread convention at the top of this comment rather than by anything the
// compiler is in a position to see.
@Observable
class AudioPlayerManager: NSObject, AVAudioPlayerDelegate {

    var isPaused: Bool = false
    var isShuffled: Bool = false
    var songLength: TimeInterval = 0.0   // total length of the song
    // Rewritten twice a second by the playback timer. Under ObservableObject that
    // made this the most expensive property in the app: every tick fired
    // objectWillChange, and any view observing the manager was invalidated whether
    // or not it had ever read the clock — which took the map, its zone overlays and
    // both CurvedText arcs down with it. Observation tracks reads per property, so
    // a tick now reaches only the progress bar and the lock-screen sync.
    var currentTime: TimeInterval = 0.0  // current playback time
    var currentContext: MusicContext = .all
    var currentSong: Song? = nil // the currently playing song, if any

    private(set) var songQueue: [Song] = [] // read-only outside; UI observes this for the queue drawer

    // The same songs as songQueue, in the order the caller handed them to us, never
    // shuffled. songQueue is what the drawer renders, so it has to hold the shuffled
    // order — which left nothing anywhere remembering what the order had been before.
    // Unshuffling used to filter the shuffled array and get the shuffled array back.
    //
    // "The order the caller handed them to us" is as much as we can promise: the views
    // pass an unsorted @Query, so this is SwiftData's own row order rather than anything
    // the user chose. It is stable enough for shuffle to round-trip within a session,
    // which is all this is for — it is not a sort, and shouldn't be mistaken for one.
    @ObservationIgnored private var orderedQueue: [Song] = []

    // None of the below is view state — it is the player, its clock, and the
    // bookkeeping the two need — so it stays out of observation. The macro would
    // otherwise track every one of them, and currentIndex and
    // ticksSinceNowPlayingSync in particular are written on the same twice-a-second
    // path as currentTime, which is precisely the traffic this task exists to stop.
    @ObservationIgnored private var audioPlayer: AVAudioPlayer? = nil
    @ObservationIgnored private var currentIndex: Int = 0 // index of the current song in the queue
    @ObservationIgnored private var playbackTimer: Timer? = nil
    @ObservationIgnored private var ticksSinceNowPlayingSync = 0 // see startPlaybackTimer
    @ObservationIgnored private var wasPlayingBeforeInterruption = false // see handleInterruption
    @ObservationIgnored private var hasActivatedSession = false // see activateSession / deactivateSession

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
        // everything below touches observable state and a run-loop Timer.
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
    // reach — musicPlayPause, skip, previous — rewrites observable state, so each one
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

            // One fetch for the whole folder, in place of the FetchDescriptor this used
            // to run per file. Whole Songs and not just their names, deliberately: the
            // existing ones go straight back to the caller, which reads every field off
            // them to build the queue — so narrowing this fetch would only move the round
            // trips from here to the first property access.
            var songsByName = existingSongsByName(in: modelContext)

            for fileName in mp3Files {
                let songName = fileName.replacingOccurrences(of: ".mp3", with: "")
                let title = songName // Use filename as title

                // Check if song already exists
                if let existing = songsByName[songName] {
                    // Deliberately not forcing isImported = false on it. A user
                    // can have imported an mp3 whose basename matches a bundled
                    // one, and clearing the flag here would drop their copy out
                    // of the library screen every launch. A record that says
                    // "imported" is a claim only the import path makes; this one
                    // has no business retracting it.
                    loadedSongs.append(existing)
                } else {
                    // isImported: false — this file ships inside the app bundle,
                    // so there is nothing in Documents/Music for the user to
                    // manage or delete. It plays; it doesn't appear in My Music.
                    // MusicContext.all.storageKey, not the literal "All" this
                    // used to be: locations holds storage keys now, and a
                    // hand-typed one is a tag that matches nothing.
                    let newSong = Song(title: title, songName: songName, artist: "Unknown Artist", locations: [MusicContext.all.storageKey], populationMin: 0, populationMax: 10000000, isImported: false)
                    modelContext.insert(newSong)

                    // Fold the new song into the index before moving on. Two files in the
                    // folder can still reduce to a single songName, and the per-file fetch
                    // caught that for free — a SwiftData fetch sees pending inserts, so the
                    // second file found the first one's unsaved row. A single fetch up front
                    // sees nothing that happens after it, so we keep it current by hand.
                    // Keyed on the model's own songName rather than the local variable,
                    // since Song.init normalizes what it is handed and an index that
                    // disagrees with the store is worse than no index at all.
                    songsByName[newSong.songName] = newSong
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
        // One fetch for the whole batch, in place of the two per file this used to run.
        // It has to stay current as we insert, because a name added here has to be
        // visible to the rest of the loop: two of the selected URLs can easily share a
        // basename — the same track picked out of two folders — and the per-file fetch
        // caught that for free, since a SwiftData fetch sees pending inserts. A snapshot
        // taken once does not, so we maintain it ourselves.
        //
        // It can go stale in one narrow way the per-file fetch couldn't: this suspends at
        // every await below, and other main-actor code could in principle insert a Song in
        // the gap. Nothing in the app does today — the importer is a single sheet, and the
        // bundle load only runs against an empty library — and the price of being wrong is
        // one duplicate row, against N round trips saved on every import.
        //
        // Whole Songs rather than the bare Set of names this used to take: the duplicate
        // branch below now writes isImported to the existing record, so the objects are
        // needed and not just their names. Narrowing the fetch would only have moved the
        // round trip to the first property access.
        var songsByName = existingSongsByName(in: modelContext)

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let songName = url.deletingPathExtension().lastPathComponent
            let destination = Self.importedMusicDirectory.appendingPathComponent("\(songName).mp3")
            let existing = songsByName[songName]

            // Copy the file in (even if a Song record already exists from a
            // previous failed attempt, the file may be missing)
            if !FileManager.default.fileExists(atPath: destination.path) || existing == nil {
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
            if let existing {
                // ...but not the flag. We are past the copy, so the mp3 is in
                // Documents/Music whether we just put it there or found it, and
                // the record has to agree or the song the user has plainly just
                // imported never shows up in My Music. Reachable two ways: the
                // name collides with a bundled song, or the row predates the flag
                // and the migration's backfill found no file to match it against.
                // Guarded rather than assigned, so an ordinary re-import doesn't
                // dirty a row that already says the right thing.
                if existing.isImported {
                    print("Song already exists, skipping record: \(songName)")
                } else {
                    existing.isImported = true
                    print("Song already exists, marking the existing record imported: \(songName)")
                }
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

            // isImported: true — we have just copied this file into
            // Documents/Music ourselves. This is the one place that claim is made.
            let newSong = Song(title: title, songName: songName, artist: artist, locations: [MusicContext.all.storageKey], populationMin: 0, populationMax: 10000000, isImported: true)
            modelContext.insert(newSong)
            // and the rest of the batch now knows about it — see the note above the fetch.
            // The model's own songName, not the local one, so the index says what the store
            // will say: Song.init normalizes the name it is given, and a URL like
            // "track.mp3.mp3" leaves the two disagreeing.
            songsByName[newSong.songName] = newSong
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

    // Every song in the store, indexed by songName. This replaces a songExists(_:in:) that
    // ran a predicated fetch per question — importing forty songs asked eighty times, and
    // loading the bundle once per file, when the answer to all of them fits in one round
    // trip.
    //
    // It had a narrower sibling, existingSongNames, which used propertiesToFetch to pull
    // one String per song for importSongs to test membership against. That went when
    // importSongs started writing isImported to the rows it finds: everything a narrowed
    // fetch leaves out comes back as a fault, so touching a second property sends SwiftData
    // straight back to the store — the exact round trip the narrowing was there to avoid.
    // Narrowing a fetch whose results get used is a false economy, and both callers use
    // them now.
    //
    // First one wins on a collision, which is the .first the per-name fetch used to take.
    // As of LR-16 that branch should be unreachable: songName carries a unique constraint,
    // and the V4 → V5 stage collapsed the duplicate rows that predate it. The closure stays
    // anyway. Dropping it means Dictionary(uniqueKeysWithValues:), which does not tolerate
    // a duplicate key — it traps — so removing it would trade an arbitrary-but-harmless
    // pick for a crash, on the strength of a guarantee no one here has been able to run
    // even once.
    private func existingSongsByName(in modelContext: ModelContext) -> [String: Song] {
        let songs = (try? modelContext.fetch(FetchDescriptor<Song>())) ?? []
        return Dictionary(songs.map { ($0.songName, $0) }, uniquingKeysWith: { existing, _ in existing })
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
    //
    // Matched on songName, here and in followCurrentSongInQueue and reloadQueue, and
    // deliberately left that way by LR-16 rather than moved to persistentModelID. The
    // constraint added in that task is what makes this a real identity test instead of a
    // guess: two rows can no longer share a name, so "the song with this name" names
    // exactly one song. Model ID would say the same thing about every row the store has
    // ever handed us, and would additionally say it about rows that were never inserted
    // into a ModelContext at all — which is what every fixture in PlaybackTests is, by
    // design. Swapping the comparison would rest roughly forty tests on the behaviour of
    // persistentModelID on an unregistered model, to replace a comparison that has just
    // been made correct.
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
            // Restore the order the songs arrived in. This used to hand the already
            // shuffled songQueue back to reloadQueue, which filtered it and got the
            // same shuffled array back out — so turning shuffle off reordered nothing.
            songQueue = orderedQueue
        }

        // Either way the playing song has just moved to a different slot while
        // currentIndex stayed pointing at the old one, which would send the next skip
        // somewhere arbitrary. This was already true of switching shuffle *on*.
        followCurrentSongInQueue()
    }

    // Point currentIndex back at whatever is playing after the queue has been reordered
    // underneath it.
    //
    // Deliberately leaves audioPlayer alone: the song hasn't changed, only its position
    // in the list has, so building a fresh player would restart it from zero — which is
    // the whole complaint this exists to fix.
    private func followCurrentSongInQueue() {
        guard let playing = currentSong,
              let index = songQueue.firstIndex(where: { $0.songName == playing.songName }) else {
            // Nothing loaded, or it's no longer in the queue. The top is as good a place
            // as any to point at, and musicPlayPause will load from there when asked.
            currentIndex = 0
            return
        }

        currentIndex = index
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
    // necessarily main, and skip() rewrites observable state and reschedules the playback
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
        // "location" was never a context — this stub has been writing a tag that
        // matches nothing since it was typed. It is unreferenced, so nothing has
        // ever run it; still, a placeholder that writes junk into the store is
        // worse than one that writes something inert but real.
        //
        // The hardcoded songName is a second, newer problem: it is the unique key
        // as of LR-16, so two calls to this collide on it. Left alone rather than
        // invented a fix for, since whoever wires this up has to supply a real
        // filename anyway — but it should not be the surprise when they do.
        let newSong = Song(title: title, songName: "filename", artist: artist, locations: [MusicContext.all.storageKey], populationMin: 0, populationMax: 9999)
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

        // shuffle was decoration until now: the body read the isShuffled property and
        // ignored the argument entirely. Every caller happens to pass isShuffled, so it
        // never misbehaved — it was just lying in wait for the first caller that didn't.
        // Kept rather than deleted because removing it means editing five call sites in
        // ContentView and LibraryView, which another task owns right now. So instead the
        // argument becomes the answer, and the published flag is made to agree with it:
        // the order the queue is actually in and the flag the shuffle button lights up
        // can no longer disagree, whichever way a caller pushes them.
        if isShuffled != shuffle {
            isShuffled = shuffle
        }

        // add only the new songs to the queue, keeping an unshuffled copy of exactly the
        // same set. This is the only place either array is rebuilt, so it is the only
        // place they can be made to match — every branch below inherits both, including
        // the empty one, where the filter leaves each of them empty together.
        orderedQueue = songs.filter { $0.isTagged(newContext) }
        songQueue = orderedQueue

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
    //
    // A second known strict-concurrency site, and one the header's list of hops doesn't
    // cover: Foundation types the block below as @Sendable, so capturing self in it is
    // reported for the same non-Sendable reason the hops are. It is safe for a stronger
    // reason than they are, in fact — the run loop this timer is attached to is the main
    // one, so the block cannot execute anywhere else — but that is a fact about the
    // scheduling thread, and the closure's type has no way to carry it.
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
