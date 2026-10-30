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
}
