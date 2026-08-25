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
//  off. isImported has since landed, as V3 below; the other two are still to
//  come and each needs its own version and its own stage.
//

import Foundation
import SwiftData

// MARK: - Adding a version
//
// 1. FREEZE the newest existing version first. V2 below still points at the
//    live Song in Song.swift, so editing that file silently rewrites what V2
//    claims the old store looked like. Before changing Song's shape, copy
//    today's Song into SongSchemaV2 as a nested class exactly the way V1 does
//    it, so V2 stops moving.
// 2. Add SongSchemaV3 holding the new shape.
// 3. Add a stage to SongMigrationPlan.stages. .lightweight only covers changes
//    SwiftData can infer on its own — adding an optional or defaulted
//    property, dropping a property, dropping an entity. Anything that needs
//    existing rows rewritten (deduplicating songName, rewriting locations from
//    display strings to stable keys) has to be a .custom stage.
// 4. Point sharedModelContainer in LittleRouteApp at the new version.
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
// user into Documents/Music, rather than shipped in the app bundle. Song is not
// re-declared: V3 is the current version, so it points at the live class in
// Song.swift and there stays exactly one definition of the model in play. The
// next version along has to freeze this one first — see step 1.
enum SongSchemaV3: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Song.self]
    }
}

// MARK: - Migration plan
enum SongMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] {
        [SongSchemaV1.self, SongSchemaV2.self, SongSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
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
    private static func backfillIsImported(in context: ModelContext) {
        guard let songs = try? context.fetch(FetchDescriptor<Song>()) else {
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
