//
//  Song.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 12/18/24.
//

import SwiftData
import AVFoundation

// The live model, and what SongSchemaV4 points at. Its shape *is* the current
// store, so changing anything stored below needs a new schema version and a
// migration stage — and the previous version has to be frozen first, or it
// stops describing the store people already have. See SongSchema.swift.
@Model
final class Song {
    var title: String
    var songName: String /* {
        // This is the actual file name of the song, without the extension
        return title.replacingOccurrences(of: ".mp3", with: "")
    } */
    var artist: String? = nil // optional artist name

    // Contexts the song will play in, held as MusicContext storage keys.
    //
    // Still [String] rather than [MusicContext] because the enum is what the
    // *app* wants and a plain array of strings is what SwiftData will store
    // without asking for a Codable box around it — and the box would change the
    // column's shape, which is a schema version's worth of risk for a type
    // annotation. The typing that actually matters is bought below instead: read
    // and write these through isTagged/setTagged and the only strings that ever
    // reach the array came out of a MusicContext.
    //
    // Until LR-15 these were the enum's *display* names ("Gyms"), so renaming a
    // case for UI reasons orphaned every tag in the store. They're stable keys
    // now ("gym"); the V3 → V4 stage in SongSchema.swift rewrote the rows that
    // predate that. The property keeps its old name because renaming it would
    // change the column, and there is nothing here worth a second migration.
    var locations: [String]
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

// MARK: - Context tags
//
// The typed way in and out of `locations`. Every reader in the app goes through
// here, so the only literal context strings left in the codebase are the enum's
// own raw values and the frozen map inside the migration stage — which is what
// makes "changing a display name leaves every tag intact" true rather than
// merely intended.
extension Song {

    // Whether this song plays in the given context.
    func isTagged(_ context: MusicContext) -> Bool {
        locations.contains(context.storageKey)
    }

    // Add or remove one tag. Idempotent in both directions: tagging something
    // already tagged is a no-op rather than a second copy of the same key, and
    // removing clears every copy in case an older write left duplicates behind.
    //
    // Doesn't save — the caller owns the ModelContext and knows whether this is
    // one edit or the middle of a batch.
    func setTagged(_ context: MusicContext, _ tagged: Bool) {
        let key = context.storageKey
        if tagged {
            guard !locations.contains(key) else { return }
            locations.append(key)
        } else {
            locations.removeAll { $0 == key }
        }
    }

    // Every context this song is tagged for, in stored order.
    //
    // compactMap rather than map: a key we don't recognise is dropped from this
    // view of the array but stays in the array itself. That matters — the
    // migration deliberately leaves strings it can't place alone, and a getter
    // that quietly deleted them on the way past would finish the job the
    // migration refused to do.
    var taggedContexts: [MusicContext] {
        locations.compactMap(MusicContext.init(storageKey:))
    }
}


