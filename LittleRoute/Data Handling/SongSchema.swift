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
//  off.
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
// V1 minus Item, and nothing else. Song is deliberately not re-declared: this
// points at the live class in Song.swift so there stays exactly one definition
// of the current model, and every other file keeps resolving `Song` the way it
// always has. Read the freeze note above before changing it.
enum SongSchemaV2: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Song.self]
    }
}

// MARK: - Migration plan
enum SongMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] {
        [SongSchemaV1.self, SongSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
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
}
