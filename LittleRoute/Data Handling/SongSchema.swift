//
//  SongSchema.swift
//  LittleRoute
//
//  The store's history, written down. Until now the container was built from a
//  bare Schema([...]) with no version attached, which made any model change a
//  coin flip — SwiftData either inferred a lightweight migration or refused to
//  open the store, and there was nowhere to say which was meant to happen.
//  Three planned changes are breaking without that: a unique constraint on
//  songName (LR-16), stable context keys in locations (LR-15), and an
//  isImported flag (LR-17). This file is the mechanism they hang their stages
//  off. isImported landed as V3, the context keys as V4 and the unique
//  constraint as V5; all three are below, each with the stage that carries the
//  existing rows across.
//

import Foundation
import SwiftData

// MARK: - Adding a version
//
// 1. FREEZE the newest existing version first. Whichever version is current
//    points at the live Song in Song.swift, so editing that file silently
//    rewrites what that version claims the old store looked like. Before
//    changing Song, copy today's Song into it as a nested class exactly the way
//    V1 does, so it stops moving. V2, V3 and V4 have all been through this.
//    Freezing a version also changes what its own stage means: a stage that
//    lands in the version you just froze has to fetch the transcription rather
//    than the live class, because the live class is no longer one of that
//    version's models. Both custom stages below have had that correction made
//    to them, one version apart.
// 2. Add the new SongSchemaVn holding the new shape.
// 3. Add a stage to SongMigrationPlan.stages. .lightweight only covers changes
//    SwiftData can infer on its own — adding an optional or defaulted
//    property, dropping a property, dropping an entity. Anything that needs
//    existing rows rewritten (deduplicating songName, rewriting locations from
//    display strings to stable keys) has to be a .custom stage. Which half of a
//    .custom stage the work goes in is a real decision and not a habit:
//    didMigrate for anything that fixes rows up once the new shape is in place,
//    willMigrate for anything the new shape would otherwise choke on. The V4 →
//    V5 dedup is the only case of the latter so far, and the comment on it says
//    why at length.
// 4. Point sharedModelContainer in LittleRouteApp at the new version.
//
// And one rule that isn't a step, because it applies to the stage rather than
// the version: a stage's knowledge of the old world has to be written down
// *inside the stage*, as literals. Never read it out of a live type. The V3 → V4
// stage rewrites display strings into MusicContext keys; if it asked
// MusicContext what those display strings were, the next person to reword a chip
// label would retroactively break the migration for everybody still upgrading
// from an old build. A migration describes history, and history has stopped
// moving.
//
// V1 is frozen permanently. It is the only description of the store that has
// actually shipped, and SwiftData identifies an existing store by matching it
// against these descriptions — if V1 drifts, a store written before the drift
// stops being recognisable and the migration fails.

// MARK: - V1 — what ships today
//
// A frozen transcription of Song.swift and Item.swift. Do not edit this to
// match a newer Song; that is the single change guaranteed to break an
// existing user's store.
//
// Only stored properties matter here: their names, types, optionality and
// defaults. The initialisers are present because @Model needs the class to be
// constructible, not because the store records them.
enum SongSchemaV1: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    // spelled out with Self. because the nested types below shadow the
    // top-level Song — worth being unambiguous about which one this means.
    static var models: [any PersistentModel.Type] {
        [Self.Item.self, Self.Song.self]
    }

    // the Xcode template's leftover. Nothing in the app ever constructed one,
    // so the Item table is empty in every store that has ever existed — but it
    // is still part of the shipped model, so V1 has to admit it exists.
    @Model
    final class Item {
        var timestamp: Date

        init(timestamp: Date) {
            self.timestamp = timestamp
        }
    }

    @Model
    final class Song {
        var title: String
        var songName: String
        var artist: String? = nil
        var locations: [String]
        var populationMin: Int = 0
        var populationMax: Int = 1000000000

        init(title: String, songName: String, artist: String?, locations: [String], populationMin: Int?, populationMax: Int?) {
            self.title = title
            self.songName = songName.replacingOccurrences(of: ".mp3", with: "")
            self.artist = artist
            self.locations = locations
            self.populationMin = populationMin ?? self.populationMin
            self.populationMax = populationMax ?? self.populationMax
        }
    }
}

// MARK: - V2 — Item dropped
//
// V1 minus Item, and nothing else. This used to point at the live class in
// Song.swift; LR-17 froze it, because adding isImported to that live class is
// exactly the edit step 1 above warns about — left pointing at Song.swift, V2
// would now claim the pre-flag store already had an isImported column, and the
// V2 → V3 stage would be migrating from a version no store was ever written in.
//
// So Song is transcribed here the same way V1 does it, and for the same reason:
// this is the shape on disk for anyone who has run a build since Item was
// dropped and before the flag existed. Do not edit it to match a newer Song.
enum SongSchemaV2: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    // Self. again — the nested Song below shadows the top-level one, and which
    // is meant here is the whole point of the file.
    static var models: [any PersistentModel.Type] {
        [Self.Song.self]
    }

    @Model
    final class Song {
        var title: String
        var songName: String
        var artist: String? = nil
        var locations: [String]
        var populationMin: Int = 0
        var populationMax: Int = 1000000000

        init(title: String, songName: String, artist: String?, locations: [String], populationMin: Int?, populationMax: Int?) {
            self.title = title
            self.songName = songName.replacingOccurrences(of: ".mp3", with: "")
            self.artist = artist
            self.locations = locations
            self.populationMin = populationMin ?? self.populationMin
            self.populationMax = populationMax ?? self.populationMax
        }
    }
}

// MARK: - V3 — isImported added
//
// V2 plus a defaulted Bool saying whether the song's mp3 was imported by the
// user into Documents/Music, rather than shipped in the app bundle.
//
// This used to point at the live class in Song.swift; LR-15 froze it. The V3 →
// V4 change is unusual in that it moves no columns at all — only the *contents*
// of locations — so leaving V3 pointing at Song.swift would have been harmless
// today and wrong the moment anyone touched the model again. Frozen now, while
// the transcription is trivially correct, rather than later under pressure.
//
// Note what "frozen" means for locations specifically: in a V3 store this array
// holds MusicContext *display* strings — "All", "Gyms", "Restaurants". That is
// the fact the V3 → V4 stage below is written against.
enum SongSchemaV3: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    // Self. again — the nested Song below shadows the top-level one.
    static var models: [any PersistentModel.Type] {
        [Self.Song.self]
    }

    @Model
    final class Song {
        var title: String
        var songName: String
        var artist: String? = nil
        var locations: [String]
        var populationMin: Int = 0
        var populationMax: Int = 1000000000
        var isImported: Bool = false

        init(title: String, songName: String, artist: String?, locations: [String], populationMin: Int?, populationMax: Int?, isImported: Bool = false) {
            self.title = title
            self.songName = songName.replacingOccurrences(of: ".mp3", with: "")
            self.artist = artist
            self.locations = locations
            self.populationMin = populationMin ?? self.populationMin
            self.populationMax = populationMax ?? self.populationMax
            self.isImported = isImported
        }
    }
}

// MARK: - V4 — locations holds stable keys
//
// Identical to V3 in shape. Nothing is added, dropped or renamed: `locations` is
// still `[String]`, and the only difference between a V3 store and a V4 one is
// what those strings say. "Gyms" became "gym" — a MusicContext storage key
// rather than its display name — so that rewording a chip label stops orphaning
// every tag in the library. See the @NOTE in MusicContext.swift.
//
// This used to point at the live class in Song.swift; LR-16 froze it. Putting
// @Attribute(.unique) on the live songName is exactly the edit step 1 warns
// about: left pointing at Song.swift, V4 would claim the store every current
// build has been writing already refused duplicate names, and the V4 → V5 stage
// would be deduplicating rows on the way out of a version that supposedly never
// allowed them — deduplicating, in other words, a problem it had just finished
// asserting could not exist. So V4 keeps meaning what it has always meant, V3's
// columns with no constraint on any of them, and says so in its own
// transcription below rather than by pointing at a file that moves.
//
// ⚠ The shape being identical is the one thing about this version a Mac has to
// confirm. SwiftData decides which stages to run by working out which version
// the store on disk is already at, and two versions that describe the same
// columns may well be indistinguishable to it — in which case a V3 store is
// taken for a V4 one and the stage below never runs.
//
// That failure is survivable, which is why this is still the shape of the fix:
// nothing is dropped or rewritten, so a store that misses the stage still holds
// every original string and a later build can rewrite them. The user's symptom
// would be tags that match nothing — an empty queue and unlit chips — not tags
// that are gone. The alternative (renaming the column to force a shape
// difference) trades that for the possibility of SwiftData inferring "drop one
// property, add another" and destroying the array outright, which is not a trade
// worth making from a machine that cannot run it once.
enum SongSchemaV4: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    // Self. again — the nested Song below shadows the top-level one.
    static var models: [any PersistentModel.Type] {
        [Self.Song.self]
    }

    @Model
    final class Song {
        var title: String
        var songName: String
        var artist: String? = nil
        var locations: [String]
        var populationMin: Int = 0
        var populationMax: Int = 1000000000
        var isImported: Bool = false

        init(title: String, songName: String, artist: String?, locations: [String], populationMin: Int?, populationMax: Int?, isImported: Bool = false) {
            self.title = title
            self.songName = songName.replacingOccurrences(of: ".mp3", with: "")
            self.artist = artist
            self.locations = locations
            self.populationMin = populationMin ?? self.populationMin
            self.populationMax = populationMax ?? self.populationMax
            self.isImported = isImported
        }
    }
}

// MARK: - V5 — songName is unique
//
// V4's columns, with a uniqueness constraint on songName. That is the whole
// change. The app has always treated the name as a song's identity — it is the
// mp3's basename, it is what the queue matches on, it is what both insert paths
// check before writing a row — while the store itself was perfectly willing to
// hold two rows claiming it. This is the version where the store agrees with
// the app.
//
// Unlike V3 → V4 this is a genuine shape change, so the ⚠ recorded on V4 should
// not carry over. That version's worry is that two descriptions listing
// identical columns may be indistinguishable to SwiftData, leaving it unable to
// tell which one a store is already at; a uniqueness constraint is part of the
// description itself rather than a different set of strings inside an unchanged
// column, so there is something here for the comparison to catch. "Should" and
// not "does" — that is reasoning about SwiftData's behaviour, not a run of it,
// and it is one more thing for a Mac to confirm.
//
// What it buys in exchange is a migration that can *fail*. A unique constraint
// cannot be applied to a column that already holds duplicates, and duplicates
// are possible in every store written so far. That is why the stage below is
// the only one in this file that does its work in willMigrate — see
// migrateV4toV5.
//
// Song is not re-declared: V5 is the current version, so it points at the live
// class in Song.swift and there stays exactly one definition of the model in
// play. The next version along has to freeze this one first — see step 1.
enum SongSchemaV5: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    // No Self. here, and the difference is the point: every version above
    // shadows the top-level Song with a frozen transcription, and this one
    // genuinely means the live model in Song.swift.
    static var models: [any PersistentModel.Type] {
        [Song.self]
    }
}

// MARK: - Migration plan
enum SongMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] {
        [SongSchemaV1.self, SongSchemaV2.self, SongSchemaV3.self, SongSchemaV4.self, SongSchemaV5.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5]
    }

    // Dropping an entity is one of the changes SwiftData infers, so this is
    // lightweight rather than custom. A custom stage exists to carry data
    // across a shape change, and here there is nothing to carry: nothing in
    // the app ever built an Item, so the table being dropped is empty
    // everywhere. A willMigrate/didMigrate block would add code that can throw
    // inside migration — a new way to fail — in exchange for moving zero rows.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SongSchemaV1.self,
        toVersion: SongSchemaV2.self
    )

    // Adding a defaulted, non-optional Bool is inferable, so the *shape* change
    // here needs nothing from us — this is .custom purely to get a didMigrate to
    // backfill in, not because SwiftData can't add the column.
    //
    // Without the backfill the shape change is a silent data-visibility bug.
    // Every existing row would arrive as isImported == false, LibraryView filters
    // on exactly that, and someone who has imported forty songs opens My Music to
    // "No imported songs yet" — with no way back, since importSongs skips a name
    // it already has. The rows and the mp3s would still be there; the user would
    // have no reason to believe it.
    static let migrateV2toV3 = MigrationStage.custom(
        fromVersion: SongSchemaV2.self,
        toVersion: SongSchemaV3.self,
        willMigrate: nil,
        didMigrate: { context in
            Self.backfillIsImported(in: context)
        }
    )

    // No shape change at all — see SongSchemaV4 for what that costs and why it
    // is still the right shape of fix. .custom exists here purely for the
    // didMigrate; there is nothing for SwiftData to infer.
    //
    // What moves is every row's `locations` array, from MusicContext display
    // names to MusicContext storage keys.
    static let migrateV3toV4 = MigrationStage.custom(
        fromVersion: SongSchemaV3.self,
        toVersion: SongSchemaV4.self,
        willMigrate: nil,
        didMigrate: { context in
            Self.rewriteLocationsAsContextKeys(in: context)
        }
    )

    // The odd one out in this file, and deliberately so: the work happens in
    // willMigrate, not didMigrate. Do not "fix" it to match the two stages
    // above.
    //
    // V5's shape change *is* the unique constraint, and a unique constraint
    // cannot be applied to a column that already holds duplicates. Left to
    // didMigrate the dedup would run after the constraint it exists to make
    // possible — the migration fails first, the container never opens, and
    // since LR-10 that drops the user into the in-memory fallback with an empty
    // library. The rows have to be one-per-name by the time the constraint
    // lands, and willMigrate is the only hook that runs before it.
    //
    // Duplicates genuinely are possible in an existing store. Nothing has ever
    // enforced this — existingSongsByName in AudioPlayerManager has been
    // arbitrarily picking a winner between colliding rows all along, and its
    // comment said as much.
    static let migrateV4toV5 = MigrationStage.custom(
        fromVersion: SongSchemaV4.self,
        toVersion: SongSchemaV5.self,
        willMigrate: { context in
            Self.collapseDuplicateSongNames(in: context)
        },
        didMigrate: nil
    )

    // MARK: - V4 → V5: one row per songName

    // Collapse rows sharing a songName down to a single row, before the
    // constraint that would refuse them arrives.
    //
    // Fetches SongSchemaV4.Song rather than the live Song, which is the same
    // rule backfillIsImported follows and not the opposite one: a stage's
    // context speaks whichever version it is currently sitting in.
    // backfillIsImported is a didMigrate, so it has already arrived and names
    // its destination; this is a willMigrate, so it hasn't left yet and names
    // its source. V4 is the shape actually on disk at this moment — the one
    // without the constraint. Asking for the live Song here would be asking the
    // store for a shape it does not have yet.
    //
    // The policy, and why each part of it is the cautious choice:
    //
    // - Exactly one survivor per name, picked deterministically: an imported row
    //   if the group has one, otherwise the first row the fetch returned. Imported
    //   wins because that is the row My Music lists and the row whose mp3 is
    //   sitting in Documents/Music; keeping a bundled twin instead would take a
    //   song the user imported off the library screen and out of reach of the
    //   swipe that deletes its file.
    //
    // - The survivor inherits every duplicate's tags, as a de-duplicated union in
    //   first-seen order — the same collapse the V3 → V4 stage does within a
    //   single row's array. Someone who tagged one copy for the gym and the other
    //   for driving tagged *that song* for both; the second row was only ever an
    //   accident of the store, and losing half their tagging to a migration they
    //   didn't ask for is the outcome worth spending code to avoid.
    //
    // - Deleting a Song row deletes no mp3. Nothing here touches the filesystem,
    //   and the file a deleted row named is the same file the survivor names —
    //   they agreed on songName, which is what made them duplicates in the first
    //   place. "The migration deleted my songs" is the fear this raises, and the
    //   answer is that it deletes duplicate *records* of one song and the song
    //   still plays afterwards.
    //
    // Nothing here throws, and the reason is slightly different from the one on
    // backfillIsImported. Throwing would fail the container open and land the
    // user in LR-10's in-memory fallback, same as ever — but giving up quietly is
    // strictly better here, because giving up still lets the constraint be
    // attempted, and a store that had no duplicates in it migrates perfectly well
    // even if this pass couldn't read it. Throwing would guarantee the bad
    // outcome in order to report a problem that may not exist. Both failure paths
    // log and carry on.
    private static func collapseDuplicateSongNames(in context: ModelContext) {
        guard let songs = try? context.fetch(FetchDescriptor<SongSchemaV4.Song>()) else {
            print("songName dedup: could not read the songs, leaving any duplicates in place")
            return
        }

        // Grouped by name, with the names kept in the order the fetch handed
        // them over. A Dictionary alone would do the grouping, but iterating one
        // is unordered, and an unordered walk would make which row survives — and
        // what order the merged tags end up in — differ between two runs over the
        // same store. A migration that can only happen once should still be able
        // to give the same answer twice.
        var order: [String] = []
        var groups: [String: [SongSchemaV4.Song]] = [:]
        for song in songs {
            if groups[song.songName] == nil { order.append(song.songName) }
            groups[song.songName, default: []].append(song)
        }

        var deleted = 0
        var collidingNames = 0

        for name in order {
            guard let group = groups[name], group.count > 1 else { continue }
            collidingNames += 1

            let survivor = group.first(where: \.isImported) ?? group[0]

            // The survivor's own tags first, then the rest of the group in fetch
            // order. Visiting the survivor twice costs nothing — its keys are
            // already in `seen` by the time the group loop reaches it — and it
            // buys the surviving row keeping its own array as a prefix instead of
            // being reshuffled into whatever order the store happened to return.
            var seen: Set<String> = []
            var merged: [String] = []
            for song in [survivor] + group {
                for key in song.locations where seen.insert(key).inserted {
                    merged.append(key)
                }
            }

            // only touch the row if the merge actually added something — an
            // untouched model is one less thing for the save below to fail on.
            if merged != survivor.locations {
                survivor.locations = merged
            }

            for song in group where song !== survivor {
                context.delete(song)
                deleted += 1
            }
        }

        do {
            try context.save()
            // Printed even when both counts are zero, which is the common case
            // and the one worth confirming: this line is how anyone with a Mac
            // finds out the stage ran at all, and silence would be
            // indistinguishable from SwiftData having skipped it.
            print("songName dedup: collapsed \(deleted) duplicate row(s) across \(collidingNames) name(s)")
        } catch {
            print("songName dedup: could not save, leaving \(deleted) duplicate row(s) in place — the unique constraint may now refuse the migration: \(error)")
        }
    }

    // MARK: - V3 → V4: display names to storage keys

    // What `locations` said in a V3 store, and what each of those means now.
    //
    // Every string on both sides is a literal, and that is the load-bearing
    // property of this table — not a stylistic one. The obvious way to write it
    // would be to walk MusicContext and fold [displayName: storageKey] out of
    // the live enum: half the lines, and wrong, because it asks the *current*
    // enum what the old display names were. The first person to reword a chip
    // label — the exact change LR-15 exists to make safe — would then silently
    // change what this migration believes was on disk in 2026, and every user
    // still upgrading from a V3 build would lose the tags that label used to
    // name. A migration is a statement about the past, and the past does not
    // get to be recomputed.
    //
    // So: frozen. Adding a MusicContext case later needs nothing here (no V3
    // store can contain a tag that didn't exist yet). Renaming a display name
    // needs nothing here either — that's the point. This table is finished.
    private static let v3DisplayNameToStorageKey: [String: String] = [
        "All": "all",
        "Gyms": "gym",
        "Restaurants": "restaurant",
        "Stores": "store",
        "Parks": "park",
        "Home": "home",
        "Work": "work",
        "Streets": "street",
        "Driving": "driving",
        "Beaches": "beach",
        "Mountains": "mountain",
        "Cities": "city",
        "Towns": "town",
        "Water": "water",
        "Rainy": "rainy",
        "Snowy": "snowy",
        "Traveling": "traveling"
    ]

    // The right-hand column, for telling "already migrated" apart from "no idea
    // what this is" in the log below. Derived from the table rather than from
    // MusicContext, so it is frozen for the same reason the table is.
    private static let v3StorageKeys: Set<String> = Set(v3DisplayNameToStorageKey.values)

    // Rewrite every row's tags in place.
    //
    // Three deliberate choices, all of them the cautious one:
    //
    // - A string the table doesn't recognise is kept exactly as it was, not
    //   dropped. Nobody knows what it is; that is a reason to leave it alone,
    //   not to delete it. An unrecognised tag is inert — it matches no context,
    //   so it costs the user nothing but a row that can't be read — while a
    //   deleted one is a tag the user made and can never get back. (Old builds
    //   could write such strings: addSong's stub used to insert the literal
    //   "location".)
    //
    // - It is idempotent. No key on the left is also a key on the right — the
    //   old names are capitalised and the new ones are not — so a value that has
    //   already been rewritten falls through the lookup untouched. Running this
    //   twice, on any mixture of migrated and unmigrated rows, gives the same
    //   answer as running it once. That matters more than it looks: if the
    //   version-detection question in SongSchemaV4 goes the wrong way, the fix
    //   is to run this again, and it needs to be safe to.
    //
    // - Duplicates collapse. "All" and "all" in the same array both become
    //   "all", and two identical tags are worth exactly one. Order is preserved
    //   so nothing the user sees reshuffles.
    //
    // Nothing here throws, for the reason spelled out on backfillIsImported: a
    // didMigrate that throws fails the container open, and since LR-10 that
    // lands the user in the in-memory fallback — an empty library and every edit
    // discarded on quit. Leaving the tags un-rewritten is a bad afternoon;
    // throwing is a lost library. Both failure paths log and give up.
    //
    // Fetches SongSchemaV4.Song rather than the live Song, and it used to say
    // Song — the same correction LR-15 made to backfillIsImported, for the same
    // reason and one version further along. This is a didMigrate, so it has
    // already arrived: its context speaks V4's models, and the live class stopped
    // being one of those the moment LR-16 froze V4 and gave it a transcription of
    // its own. The two shapes are still identical today, so the old spelling
    // would very likely have gone on working — which is exactly why it is worth
    // changing now, while it is a rename and not a debugging session.
    private static func rewriteLocationsAsContextKeys(in context: ModelContext) {
        guard let songs = try? context.fetch(FetchDescriptor<SongSchemaV4.Song>()) else {
            print("context key migration: could not read the migrated songs, leaving every tag in its old spelling")
            return
        }

        var rewritten = 0
        var unrecognised: Set<String> = []

        for song in songs {
            var seen: Set<String> = []
            var updated: [String] = []
            for stored in song.locations {
                let mapped = v3DisplayNameToStorageKey[stored]
                // "already a key" and "we have no idea what this is" both fall
                // through the lookup, and only the second is worth a log line —
                // otherwise a re-run would report the whole library as junk.
                // Checked against the table's own values, so this stays as
                // frozen as the table is.
                if mapped == nil, !v3StorageKeys.contains(stored) {
                    unrecognised.insert(stored)
                }
                let key = mapped ?? stored
                // second and later copies of the same tag are worth nothing;
                // insert(_:).inserted is false for them, and order is preserved
                // for the ones that survive
                guard seen.insert(key).inserted else { continue }
                updated.append(key)
            }
            // only touch the row if something actually changed — an untouched
            // model is one less thing for the save below to fail on.
            guard updated != song.locations else { continue }
            song.locations = updated
            rewritten += 1
        }

        if !unrecognised.isEmpty {
            // sorted so the line is stable between runs and worth diffing
            print("context key migration: kept \(unrecognised.count) distinct tag(s) naming no context, verbatim: \(unrecognised.sorted())")
        }

        do {
            try context.save()
            print("context key migration: rewrote tags on \(rewritten) of \(songs.count) songs")
        } catch {
            print("context key migration: could not save, leaving every tag in its old spelling: \(error)")
        }
    }

    // MARK: - V2 → V3: the isImported backfill

    // Recover the flag for rows written before it existed.
    //
    // The only thing that has ever known whether a song was imported is the
    // filesystem — Documents/Music holds the imported mp3s and nothing else — so
    // this asks it the same question LibraryView used to ask on every body
    // evaluation, once per song, once ever.
    //
    // Deliberately one fileExists per song rather than one directory listing
    // matched against songName. A listing would be one syscall instead of N, but
    // membership in a Set of basenames is not the same test as fileExists: the
    // volume is case- and normalization-insensitive and a Swift String compare
    // is neither, so the two can disagree on a name with an accent or an odd
    // capitalisation. This is a one-time pass off the main thread, where N stats
    // cost nothing we can measure — and being bit-for-bit the predicate we are
    // replacing is worth more here than the syscall.
    //
    // Nothing in it throws. A didMigrate that throws fails the whole container
    // open, and since LR-10 that lands the user in the in-memory fallback: an
    // empty library and every edit discarded on quit. That is a far worse outcome
    // than the flags staying at their default, which is merely the un-backfilled
    // state we would have had anyway. So both failure paths log and give up.
    //
    // Fetches SongSchemaV3.Song rather than the live Song, which is a change
    // LR-15 had to make when it froze V3: this stage's destination is V3, so the
    // context it is handed speaks V3's models, and the live class stopped being
    // one of them the moment V3 got its own transcription. The two shapes happen
    // to be identical today — V3 → V4 moves no columns — so the old spelling
    // would very likely still have worked, which is exactly the kind of luck not
    // worth relying on. Naming the version the stage lands in is simply what the
    // stage means.
    private static func backfillIsImported(in context: ModelContext) {
        guard let songs = try? context.fetch(FetchDescriptor<SongSchemaV3.Song>()) else {
            print("isImported backfill: could not read the migrated songs, leaving every flag at its default")
            return
        }

        // resolved once; the accessor creates the directory if it's missing, and
        // there is no reason to ask it per song.
        let importedDirectory = AudioPlayerManager.importedMusicDirectory
        var flagged = 0

        for song in songs {
            let file = importedDirectory.appendingPathComponent("\(song.songName).mp3")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            song.isImported = true
            flagged += 1
        }

        do {
            try context.save()
            print("isImported backfill: flagged \(flagged) of \(songs.count) songs as imported")
        } catch {
            print("isImported backfill: could not save, leaving every flag at its default: \(error)")
        }
    }
}
