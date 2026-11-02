import Testing
import Foundation
import SwiftData
@testable import LittleRoute

@MainActor
struct MigrationTests {
    @Test func freshPersistentStoreReopensWithTheCompleteMigrationPlan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LittleRoute-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(versionedSchema: SongSchemaV5.self)
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("library.store"))
        do {
            let container = try ModelContainer(for: schema, migrationPlan: SongMigrationPlan.self, configurations: [configuration])
            container.mainContext.insert(Song(title: "Fixture", songName: "fixture", artist: "Test",
                                              locations: ["park"], populationMin: 0, populationMax: 1))
            try container.mainContext.save()
        }
        let reopened = try ModelContainer(for: schema, migrationPlan: SongMigrationPlan.self, configurations: [configuration])
        let songs = try reopened.mainContext.fetch(FetchDescriptor<Song>())
        #expect(songs.count == 1)
        #expect(songs.first?.locations == ["park"])
    }

    @Test func legacyTagsAndDuplicateRowsSurviveUpgrade() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LittleRoute-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.store")
        do {
            let schema = Schema(versionedSchema: SongSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: url)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.insert(SongSchemaV1.Song(title: "Fixture", songName: "fixture", artist: "Test",
                                                           locations: ["Parks"], populationMin: 0, populationMax: 1))
            container.mainContext.insert(SongSchemaV1.Song(title: "Fixture", songName: "fixture", artist: "Test",
                                                           locations: ["Gyms"], populationMin: 0, populationMax: 1))
            try container.mainContext.save()
        }
        let schema = Schema(versionedSchema: SongSchemaV5.self)
        let upgraded = try ModelContainer(for: schema, migrationPlan: SongMigrationPlan.self,
                                          configurations: [ModelConfiguration(schema: schema, url: url)])
        let songs = try upgraded.mainContext.fetch(FetchDescriptor<Song>())
        #expect(songs.count == 1)
        #expect(Set(songs.first?.locations ?? []) == ["park", "gym"])
    }

    @Test(arguments: [2, 3, 4])
    func laterLegacyStoresPreserveTagsAndSource(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LittleRoute-v\(version)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.store")
        let name = "fixture-\(UUID().uuidString)"
        do {
            let schema: Schema
            switch version {
            case 2: schema = Schema(versionedSchema: SongSchemaV2.self)
            case 3: schema = Schema(versionedSchema: SongSchemaV3.self)
            default: schema = Schema(versionedSchema: SongSchemaV4.self)
            }
            let container = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url)])
            switch version {
            case 2:
                container.mainContext.insert(SongSchemaV2.Song(title: "Fixture", songName: name, artist: nil,
                    locations: ["Parks", "legacy-custom"], populationMin: 0, populationMax: 1))
            case 3:
                container.mainContext.insert(SongSchemaV3.Song(title: "Fixture", songName: name, artist: nil,
                    locations: ["Parks", "legacy-custom"], populationMin: 0, populationMax: 1, isImported: true))
            default:
                container.mainContext.insert(SongSchemaV4.Song(title: "Fixture", songName: name, artist: nil,
                    locations: ["park", "legacy-custom"], populationMin: 0, populationMax: 1, isImported: true))
            }
            try container.mainContext.save()
        }
        let schema = Schema(versionedSchema: SongSchemaV5.self)
        let upgraded = try ModelContainer(for: schema, migrationPlan: SongMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)])
        let songs = try upgraded.mainContext.fetch(FetchDescriptor<Song>())
        #expect(songs.count == 1)
        #expect(songs.first?.songName == name)
        #expect(Set(songs.first?.locations ?? []) == ["park", "legacy-custom"])
        #expect(songs.first?.isImported == (version >= 3))
    }
}
