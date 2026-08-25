//
//  PlaybackTests.swift
//  LittleRouteTests
//
//  Coverage for the queue mechanics in AudioPlayerManager: what reloadQueue
//  builds, where currentIndex ends up afterwards, how shuffle round-trips, and
//  what skip / previous do at the ends of the list and on nothing at all.
//
//  MARK: What these can and cannot reach
//
//  AudioPlayerManager is a private-init singleton whose init takes the audio
//  category, registers remote commands and subscribes to session notifications,
//  and whose loadAudio builds a real AVAudioPlayer from a real .mp3 on disk.
//  None of that can be stubbed from out here without changing the class, and
//  the class belongs to another task this wave — so these tests deliberately
//  stay on the half that is pure list manipulation:
//
//    - filtering songs by context, and the order that comes out
//    - currentIndex following the playing song through a rebuild or a shuffle
//    - skip / previous wrapping at both ends
//    - the empty-queue guards
//
//  Not covered, and not coverable from a test target as the class stands:
//
//    - anything that needs an AVAudioPlayer to actually exist. There are no
//      audio files here, so loadAudio always fails its URL lookup and leaves
//      audioPlayer nil. That is fine for the assertions below — skip() and
//      previous() move currentIndex and publish currentSong *before* they call
//      loadAudio — but it means isPaused, songLength, currentTime and progress
//      are only meaningful here on the teardown path, where reloadQueue writes
//      them directly.
//    - musicPlayPause's play/pause toggle, which needs a non-nil audioPlayer.
//    - audioPlayerDidFinishPlaying, whose parameter is a non-optional
//      AVAudioPlayer we have no way to build.
//    - the interruption and route-change handlers. They are reachable by
//      posting to NotificationCenter, but they hop to main and lean on real
//      session state, so they belong with the interruption task rather than
//      here.
//    - the isOtherAudioPlaying half of startPlaybackIfNothingElseIsPlaying,
//      which is a property of the device, not of this class.
//
//  A second suite at the bottom covers Song's context tags, which is what the
//  queue filter is really asking about — it lives here rather than in its own
//  file because "which songs are in the queue" and "which contexts is this song
//  tagged for" are two readings of the same array.
//

import Testing
import Foundation
import SwiftData
@testable import LittleRoute

// .serialized because every test in here mutates the same object: there is one
// AudioPlayerManager in the process and no way to make a second. Swift Testing
// runs tests in parallel by default, which for a shared singleton means one
// test's reloadQueue landing in the middle of another's skip.
//
// @MainActor because the class says at the top of its own file that everything
// on it expects the main thread — it writes @Published state and schedules a
// run-loop Timer.
@MainActor
@Suite(.serialized)
struct PlaybackTests {

    // MARK: Fixtures
    //
    // Song is a SwiftData @Model, but nothing here needs it to be *stored*: the
    // queue is a plain [Song] and every code path under test reads title,
    // songName and locations off the instance. An unregistered model answers
    // those from its own backing data, so these stay standalone rather than
    // dragging in an in-memory ModelContainer and a ModelContext per test.
    // (If a future SwiftData release makes unregistered instances unusable,
    // this one function is the only place that has to learn about containers.)
    //
    // songName is what the queue matches on — reloadQueue,
    // followCurrentSongInQueue and play(song:) all locate a song by comparing
    // it — so every fixture below gets a distinct one.
    // storageKey rather than rawValue, which is the same string today and the
    // point of LR-15 tomorrow: a fixture built from display names would go on
    // compiling and start matching nothing the moment somebody reworded a chip.
    private func song(_ name: String, contexts: [MusicContext] = [.all]) -> Song {
        Song(title: name,
             songName: name,
             artist: "Test Artist",
             locations: contexts.map(\.storageKey),
             populationMin: 0,
             populationMax: 1_000_000)
    }

    private func songs(_ names: String..., contexts: [MusicContext] = [.all]) -> [Song] {
        names.map { song($0, contexts: contexts) }
    }

    // The test host is the real app, so ContentView.onAppear has already run
    // against this same instance and may have loaded the bundled Music folder
    // into it before the first test here executes. Each test therefore starts
    // by wiping the singleton, using nothing but its public API.
    //
    // The empty-queue branch of reloadQueue is a complete teardown by design —
    // it stops and nils the player, clears currentSong, puts currentIndex back
    // to 0, stops the progress timer, zeroes songLength and currentTime and
    // sets isPaused — which makes it exactly the reset we would otherwise have
    // had to ask for a test hook to get.
    @discardableResult
    private func reset() -> AudioPlayerManager {
        let manager = AudioPlayerManager.shared
        manager.reloadQueue(newContext: .all, shuffle: false, songs: [])
        // reloadQueue filters *by* a context but never publishes one; only
        // switchContext writes currentContext. Pin it so the switchContext
        // tests below start somewhere known.
        manager.currentContext = .all
        return manager
    }

    private func manager(loading songs: [Song],
                         context: MusicContext = .all,
                         shuffle: Bool = false) -> AudioPlayerManager {
        let manager = reset()
        manager.reloadQueue(newContext: context, shuffle: shuffle, songs: songs)
        return manager
    }

    // currentIndex is private, so no test can read it. What it can do is nudge
    // the queue and see where it lands: skip() publishes songQueue[(index + 1)
    // % count]. Every assertion below about "the index followed the song" is
    // really an assertion about where the next skip goes, which is the thing
    // the user would notice anyway.

    // MARK: Queue construction

    @Test func queueHoldsOnlyTheSongsTaggedForTheContext() {
        let beachOnly = song("beach-only", contexts: [.beach])
        let both = song("beach-and-gym", contexts: [.beach, .gym])
        let gymOnly = song("gym-only", contexts: [.gym])

        let manager = manager(loading: [beachOnly, both, gymOnly], context: .beach)

        #expect(manager.songQueue.map(\.songName) == ["beach-only", "beach-and-gym"])
    }

    // The filter is order-preserving, and nothing sorts afterwards, so the
    // queue comes out in the order the caller handed the songs over. That is
    // the promise orderedQueue is built on.
    @Test func unshuffledQueueKeepsTheCallersOrder() {
        let library = songs("d", "a", "c", "b")

        let manager = manager(loading: library)

        #expect(manager.songQueue.map(\.songName) == ["d", "a", "c", "b"])
    }

    @Test func loadingAQueueSelectsTheTopSongWithoutPlayingIt() {
        let manager = manager(loading: songs("a", "b", "c"))

        #expect(manager.currentSong?.songName == "a")
        // reset() left this paused and loading a queue does not call play, so a
        // false here would mean reloadQueue had started the music by itself.
        #expect(manager.isPaused)
    }

    // MARK: reloadQueue preserving the playing song
    //
    // The branch that exists because toggling a single context chip used to
    // stop the music: if the song that is playing is still in the rebuilt
    // queue, follow it to its new index and leave the player alone.

    @Test func reloadQueueFollowsTheSurvivingSongToItsNewIndex() {
        // c is third in the .all queue and first in the .beach one, so
        // currentIndex has to move with it — left at 2 the next skip would
        // start from wherever index 2 now happens to be.
        let a = song("a")
        let b = song("b")
        let c = song("c", contexts: [.all, .beach])
        let d = song("d", contexts: [.all, .beach])
        let e = song("e", contexts: [.all, .beach])
        let library = [a, b, c, d, e]

        let manager = manager(loading: library)
        manager.skip() // a -> b
        manager.skip() // b -> c
        #expect(manager.currentSong?.songName == "c")

        manager.reloadQueue(newContext: .beach, shuffle: false, songs: library)

        #expect(manager.songQueue.map(\.songName) == ["c", "d", "e"])
        // the same object, not a fresh lookup of an equal one: this branch must
        // not disturb what is loaded
        #expect(manager.currentSong === c)
        // and the index came with it
        manager.skip()
        #expect(manager.currentSong?.songName == "d")
    }

    // The other half of the same branch: a song that did not survive the
    // rebuild cannot be followed, so the queue starts again from the top.
    @Test func reloadQueueStartsAtTheTopWhenThePlayingSongIsGone() {
        let a = song("a") // .all only — falls out of the .beach queue
        let b = song("b", contexts: [.all, .beach])
        let c = song("c", contexts: [.all, .beach])
        let library = [a, b, c]

        let manager = manager(loading: library)
        #expect(manager.currentSong?.songName == "a")

        manager.reloadQueue(newContext: .beach, shuffle: false, songs: library)

        #expect(manager.songQueue.map(\.songName) == ["b", "c"])
        #expect(manager.currentSong?.songName == "b")
        manager.skip()
        #expect(manager.currentSong?.songName == "c")
    }

    // keepCurrentSong: false is what the crossfade in switchContext passes —
    // it has already faded the old song out, so it wants a different track even
    // if the old one also fits the new context.
    @Test func keepCurrentSongFalseRestartsAtTheTopEvenIfTheSongSurvived() {
        let library = songs("a", "b", "c", contexts: [.all, .beach])

        let manager = manager(loading: library)
        manager.skip() // a -> b
        #expect(manager.currentSong?.songName == "b")

        manager.reloadQueue(newContext: .beach, shuffle: false, songs: library, keepCurrentSong: false)

        #expect(manager.songQueue.map(\.songName) == ["a", "b", "c"])
        #expect(manager.currentSong?.songName == "a")
    }

    // MARK: Shuffle
    //
    // orderedQueue — the unshuffled copy that unshuffling restores from — is
    // private, so none of these can look at it directly. The round trip is the
    // observable form of the same claim: capture songQueue unshuffled, toggle
    // on, toggle off, and it has to be back.

    @Test func shuffleRoundTripsBackToTheOrderTheSongsArrivedIn() {
        let library = songs("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8")
        let manager = manager(loading: library)
        let ordered = manager.songQueue.map(\.songName)

        manager.toggleShuffle()
        #expect(manager.isShuffled)
        // shuffling is a permutation: same songs, same count, nothing dropped
        #expect(manager.songQueue.count == ordered.count)
        #expect(Set(manager.songQueue.map(\.songName)) == Set(ordered))

        manager.toggleShuffle()
        #expect(!manager.isShuffled)
        #expect(manager.songQueue.map(\.songName) == ordered)
    }

    // Turning shuffle off used to hand the already-shuffled songQueue back to
    // reloadQueue, which filtered it and returned the same shuffled array — so
    // each cycle left the queue in a new arbitrary order and the original was
    // gone for good. Ten cycles is well past where that would show.
    @Test func repeatedShuffleCyclesStillLandOnTheOriginalOrder() {
        let library = songs("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8")
        let manager = manager(loading: library)
        let ordered = manager.songQueue.map(\.songName)

        for _ in 0..<10 {
            manager.toggleShuffle()
            manager.toggleShuffle()
        }

        #expect(!manager.isShuffled)
        #expect(manager.songQueue.map(\.songName) == ordered)
    }

    // The round-trip tests above would all pass if shuffle did nothing at all,
    // so this pins down that it reorders. Statistical, but only nominally: one
    // shuffle of eight songs returns the original order once in 8! ≈ 40,000
    // tries, and this asks for ten independent shuffles to *all* do it.
    @Test func togglingShuffleOnActuallyReordersTheQueue() {
        let library = songs("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8")
        let manager = manager(loading: library)
        let ordered = manager.songQueue.map(\.songName)

        var everDiffered = false
        for _ in 0..<10 {
            manager.toggleShuffle()
            if manager.songQueue.map(\.songName) != ordered { everDiffered = true }
            manager.toggleShuffle()
        }

        #expect(everDiffered)
    }

    // Both directions reorder the queue underneath a song that is playing, so
    // both have to point currentIndex back at it. Without that the next skip
    // goes to whatever landed in the old slot.
    @Test func shufflingOnKeepsTheIndexOnThePlayingSong() throws {
        let library = songs("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8")
        let manager = manager(loading: library)
        manager.skip() // s1 -> s2
        manager.skip() // s2 -> s3
        let playing = manager.currentSong
        #expect(playing?.songName == "s3")

        manager.toggleShuffle()

        // the song itself must not change — only its position did
        #expect(manager.currentSong === playing)

        let shuffled = manager.songQueue.map(\.songName)
        let position = try #require(shuffled.firstIndex(of: "s3"))
        manager.skip()
        #expect(manager.currentSong?.songName == shuffled[(position + 1) % shuffled.count])
    }

    @Test func shufflingOffKeepsTheIndexOnThePlayingSong() throws {
        let library = songs("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8")
        let manager = manager(loading: library)
        manager.toggleShuffle()
        manager.skip()
        manager.skip()
        let playing = try #require(manager.currentSong)

        manager.toggleShuffle()

        #expect(!manager.isShuffled)
        #expect(manager.currentSong === playing)

        let ordered = manager.songQueue.map(\.songName)
        let position = try #require(ordered.firstIndex(of: playing.songName))
        manager.skip()
        #expect(manager.currentSong?.songName == ordered[(position + 1) % ordered.count])
    }

    // reloadQueue's shuffle argument used to be decoration — the body read the
    // isShuffled property and ignored it. This pins both halves of the fix: the
    // argument decides the order, the published flag is made to agree with it,
    // and orderedQueue is still captured *before* the shuffle, so unshuffling
    // afterwards finds the caller's order rather than the shuffled one.
    @Test func reloadQueueShufflesOnItsArgumentAndKeepsTheFlagHonest() {
        let library = songs("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8")
        let names = library.map(\.songName)
        let manager = manager(loading: library)
        #expect(!manager.isShuffled)

        manager.reloadQueue(newContext: .all, shuffle: true, songs: library)

        #expect(manager.isShuffled)
        #expect(Set(manager.songQueue.map(\.songName)) == Set(names))

        manager.toggleShuffle()
        #expect(!manager.isShuffled)
        #expect(manager.songQueue.map(\.songName) == names)
    }

    // MARK: skip / previous at the queue boundaries

    @Test func skipWrapsFromTheLastSongToTheFirst() {
        let manager = manager(loading: songs("a", "b", "c"))

        manager.skip()
        #expect(manager.currentSong?.songName == "b")
        manager.skip()
        #expect(manager.currentSong?.songName == "c")
        manager.skip()
        #expect(manager.currentSong?.songName == "a")
    }

    // (currentIndex - 1) on its own would be -1 here, and Swift's % keeps the
    // sign of the dividend — so the + count is what stops this trapping on a
    // negative subscript.
    @Test func previousWrapsFromTheFirstSongToTheLast() {
        let manager = manager(loading: songs("a", "b", "c"))
        #expect(manager.currentSong?.songName == "a")

        manager.previous()

        #expect(manager.currentSong?.songName == "c")
    }

    @Test func previousUndoesSkip() {
        let manager = manager(loading: songs("a", "b", "c"))

        manager.skip()
        manager.skip()
        manager.previous()

        #expect(manager.currentSong?.songName == "b")
    }

    // A one-song queue is where both moduli are at their most awkward:
    // (0 + 1) % 1 and (0 - 1 + 1) % 1 both have to come back to 0.
    @Test func singleSongQueueStaysOnThatSongInBothDirections() {
        let only = song("only")
        let manager = manager(loading: [only])

        manager.skip()
        #expect(manager.currentSong === only)

        manager.previous()
        #expect(manager.currentSong === only)
    }

    // MARK: play(song:)

    @Test func playingASongInTheQueueMovesTheIndexToIt() {
        let library = songs("a", "b", "c", "d")
        let manager = manager(loading: library)

        manager.play(song: library[2])

        #expect(manager.currentSong?.songName == "c")
        manager.skip()
        #expect(manager.currentSong?.songName == "d")
    }

    @Test func playingASongThatIsNotInTheQueueChangesNothing() {
        let library = songs("a", "b", "c")
        let outsider = song("outsider", contexts: [.gym])
        let manager = manager(loading: library)
        #expect(manager.currentSong?.songName == "a")

        manager.play(song: outsider)

        #expect(manager.currentSong?.songName == "a")
        // the index is untouched too, not just the published song
        manager.skip()
        #expect(manager.currentSong?.songName == "b")
    }

    // MARK: Empty-queue guards

    // Reloading into a context nothing is tagged for is a teardown, not just an
    // empty list: leaving a stale currentSong behind would have the UI showing
    // a song the drawer no longer contains.
    @Test func reloadingIntoAContextThatMatchesNothingTearsThePlayerDown() {
        let library = songs("a", "b", "c") // .all only
        let manager = manager(loading: library)
        manager.skip()
        #expect(manager.currentSong != nil)

        manager.reloadQueue(newContext: .gym, shuffle: false, songs: library)

        #expect(manager.songQueue.isEmpty)
        #expect(manager.currentSong == nil)
        #expect(manager.isPaused)
        #expect(manager.songLength == 0)
        #expect(manager.currentTime == 0)
        // and progress divides by songLength, so it has to survive the zero
        #expect(manager.progress == 0)
    }

    // Same teardown, reached the other way — an empty library rather than a
    // context that excludes everything.
    @Test func reloadingWithNoSongsAtAllTearsThePlayerDown() {
        let manager = manager(loading: songs("a", "b", "c"))
        #expect(!manager.songQueue.isEmpty)

        manager.reloadQueue(newContext: .all, shuffle: false, songs: [])

        #expect(manager.songQueue.isEmpty)
        #expect(manager.currentSong == nil)
        #expect(manager.isPaused)
    }

    // % 0 traps, so the guards at the top of skip() and previous() are the only
    // thing between an empty queue and a crash.
    @Test func skipAndPreviousOnAnEmptyQueueDoNothing() {
        let manager = reset()
        #expect(manager.songQueue.isEmpty)

        manager.skip()
        #expect(manager.currentSong == nil)
        #expect(manager.songQueue.isEmpty)

        manager.previous()
        #expect(manager.currentSong == nil)
        #expect(manager.songQueue.isEmpty)
    }

    // Only the empty-queue half of this is testable from here — whether
    // something else is playing is a property of the device. That guard is
    // still worth pinning: it is the one that runs on every launch before the
    // library has loaded.
    @Test func startingPlaybackWithAnEmptyQueueDoesNothing() {
        let manager = reset()

        manager.startPlaybackIfNothingElseIsPlaying()

        #expect(manager.currentSong == nil)
        #expect(manager.songQueue.isEmpty)
        #expect(manager.isPaused)
    }

    // The teardown resets currentIndex as well as the published state, so a
    // context that comes back after matching nothing starts from the top rather
    // than from wherever the old queue had got to.
    @Test func aQueueRefilledAfterATeardownStartsFromTheTop() {
        let library = songs("a", "b", "c")
        let manager = manager(loading: library)
        manager.skip()
        manager.skip()
        #expect(manager.currentSong?.songName == "c")

        manager.reloadQueue(newContext: .gym, shuffle: false, songs: library) // empties
        manager.reloadQueue(newContext: .all, shuffle: false, songs: library) // refills

        #expect(manager.songQueue.map(\.songName) == ["a", "b", "c"])
        #expect(manager.currentSong?.songName == "a")
    }

    // MARK: switchContext
    //
    // Only the silent path is reachable here. With no audioPlayer there is
    // nothing audible to fade, so switchContext swaps the queue synchronously
    // and returns; the crossfade branch needs a playing AVAudioPlayer and a
    // 1.5s asyncAfter, neither of which belongs in a unit test.

    @Test func switchingContextSwapsTheQueueWhenNothingIsPlaying() {
        let a = song("a")
        let b = song("b", contexts: [.all, .beach])
        let c = song("c", contexts: [.beach])
        let library = [a, b, c]

        let manager = manager(loading: library)
        #expect(manager.currentContext == .all)

        manager.switchContext(to: .beach, songs: library)

        #expect(manager.currentContext == .beach)
        #expect(manager.songQueue.map(\.songName) == ["b", "c"])
    }

    // The guard at the top: re-announcing the context we are already in must
    // not rebuild anything. The song list handed over here is deliberately
    // wrong, so a rebuild would be visible.
    @Test func switchingToTheContextAlreadyPlayingIsANoOp() {
        let library = songs("a", "b", "c")
        let manager = manager(loading: library)
        manager.skip()
        #expect(manager.currentSong?.songName == "b")

        manager.switchContext(to: .all, songs: [library[0]])

        #expect(manager.songQueue.map(\.songName) == ["a", "b", "c"])
        #expect(manager.currentSong?.songName == "b")
    }
}

// MARK: - Context tags
//
// LR-15 split MusicContext's storage key from its display name, so what lands
// in Song.locations is "gym" rather than "Gyms" and rewording a chip label can
// no longer orphan a tag. These are the assertions that stay true only while
// that split holds — which is exactly the part a future display rename would
// break silently, since it wouldn't break the build.
//
// Not @MainActor and not serialized, unlike the suite above: nothing here goes
// near the singleton. Every test builds its own unregistered Song, which
// answers from its own backing data — see the fixture note at the top for why
// that needs no ModelContainer.
struct SongContextTagTests {

    private func makeSong(locations: [String]) -> Song {
        Song(title: "t", songName: "t", artist: nil,
             locations: locations, populationMin: nil, populationMax: nil)
    }

    // The one that matters. If these two ever come back equal, the storage key
    // has quietly gone back to being the label and the next rename orphans
    // everything again.
    @Test func theStoredKeyIsNotTheDisplayedLabel() {
        #expect(MusicContext.gym.storageKey == "gym")
        #expect(MusicContext.gym.displayName == "Gyms")
        #expect(MusicContext.gym.storageKey != MusicContext.gym.displayName)
    }

    // The two spellings live in separate namespaces, and nothing that reads a
    // stored tag will accept a label. This is also what makes the V3 → V4
    // migration idempotent: no old display name is also a new key, so a value
    // that has already been rewritten falls through that map untouched.
    @Test func aDisplayNameIsNotAValidStorageKey() {
        #expect(MusicContext(storageKey: "Gyms") == nil)
        #expect(MusicContext(storageKey: "All") == nil)
        #expect(MusicContext(storageKey: "Restaurants") == nil)
    }

    @Test func everyKeyRoundTripsBackToItsContext() {
        // spelled out rather than derived: a list built by walking the enum
        // would agree with itself no matter what the enum said.
        let contexts: [MusicContext] = [
            .all, .gym, .restaurant, .store, .park, .home, .work,
            .street, .driving, .beach, .mountain, .city, .town, .water,
            .rainy, .snowy, .traveling
        ]
        for context in contexts {
            #expect(MusicContext(storageKey: context.storageKey) == context)
        }
        // and no two contexts share one
        #expect(Set(contexts.map(\.storageKey)).count == contexts.count)
    }

    @Test func taggingWritesTheKeyAndReadsBackAsTheContext() {
        let song = makeSong(locations: [])

        song.setTagged(.beach, true)

        #expect(song.locations == ["beach"])
        #expect(song.isTagged(.beach))
        #expect(song.taggedContexts == [.beach])
    }

    // Tagging something already tagged is a no-op rather than a second copy,
    // and untagging clears every copy in case an older write left duplicates.
    @Test func taggingIsIdempotentInBothDirections() {
        let song = makeSong(locations: ["gym", "gym"])

        song.setTagged(.gym, true)
        #expect(song.locations == ["gym", "gym"])

        song.setTagged(.gym, false)
        #expect(song.locations.isEmpty)

        song.setTagged(.gym, false)
        #expect(song.locations.isEmpty)
    }

    // A string that names no context is kept, not deleted. The migration
    // deliberately leaves values it can't place alone, so a getter that dropped
    // them on the way past would finish the job the migration refused to do.
    @Test func aTagThatNamesNoContextSurvivesButMatchesNothing() {
        let song = makeSong(locations: ["gym", "location", "Beaches"])

        #expect(song.taggedContexts == [.gym])
        #expect(!song.isTagged(.beach)) // the old display spelling doesn't count
        #expect(song.locations == ["gym", "location", "Beaches"])

        // and editing an unrelated tag leaves them exactly where they were
        song.setTagged(.park, true)
        #expect(song.locations == ["gym", "location", "Beaches", "park"])
    }
}
