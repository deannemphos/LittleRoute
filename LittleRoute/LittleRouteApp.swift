//
//  LittleRouteApp.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 12/4/24.
//

import SwiftUI
import SwiftData

// MARK: - Store health
//
// Which of the two stores the app actually ended up on. This is decided once,
// before any view exists, and nothing re-opens the store afterwards — so it's
// a plain value handed down the environment rather than an observable object.
//
// It exists because the in-memory fallback below is *not* a silent equivalent
// of the real thing: on it the library reads as empty and every edit or import
// is thrown away on quit. Something has to be able to tell the user that, or
// they'll re-import their whole library into a store that forgets it.
enum ModelStoreHealth {

    // the on-disk store opened normally. edits survive a quit.
    case onDisk

    // the on-disk store refused to open, so we're running in memory. reason is
    // the underlying error's description — diagnostic text for a bug report or
    // a log, not user-facing copy.
    case inMemory(reason: String)

    var isDegraded: Bool {
        if case .inMemory = self { return true }
        return false
    }
}

private struct ModelStoreHealthKey: EnvironmentKey {
    // a view with nothing injected above it (a preview, say) should assume the
    // normal case rather than warn about a problem that isn't there.
    static let defaultValue: ModelStoreHealth = .onDisk
}

extension EnvironmentValues {
    var modelStoreHealth: ModelStoreHealth {
        get { self[ModelStoreHealthKey.self] }
        set { self[ModelStoreHealthKey.self] = newValue }
    }
}

@main
struct LittleRouteApp: App {

    // MARK: - App-scoped services
    //
    // These live at app scope, not inside ContentView. SwiftUI re-creates View
    // structs whenever it likes, and @ObservedObject doesn't own its object —
    // so a ContentView re-init used to spin up a second CLLocationManager,
    // throw away the detector's accumulated debt / dwell / buffer state, and
    // leak the old poll timer. @State keeps one instance alive for the whole
    // process. ContextDetector only holds the handler weakly, so something up
    // here has to be the strong owner of LocationHandler too.
    @State private var locationHandler: LocationHandler
    @State private var contextDetector: ContextDetector

    // MARK: - Persistence
    //
    // Built from the current VersionedSchema rather than a bare model list, so
    // the schema carries a version identifier and the migration plan has a
    // destination to migrate *to*. Item is gone from the schema here; it gets
    // dropped by the V1 → V2 stage rather than by quietly disappearing from
    // the list. See SongSchema.swift.
    //
    // This has to name the *newest* version — it is the shape the app expects
    // to be running against and the destination the plan migrates to. Pointing
    // it at an older one leaves every @Query in the app asking for a model the
    // container was not built for. Bumping it is step 4 of the checklist at the
    // top of SongSchema.swift; V3 added Song.isImported and V4 rewrote
    // Song.locations from context display names to stable context keys.
    //
    // Both of these are decided together in makeModelContainer(), which is why
    // they're assigned in init() rather than each carrying its own initialiser
    // closure.
    let sharedModelContainer: ModelContainer
    let storeHealth: ModelStoreHealth

    init() {
        let (container, health) = Self.makeModelContainer()
        sharedModelContainer = container
        storeHealth = health

        // The detector needs the handler, so they're built together here and
        // seeded into @State rather than declared with inline defaults.
        //
        // The weather provider is spelled out because it no longer defaults to
        // WeatherKitProvider() — a default argument that opens a network client
        // is a live dependency hiding in a signature. This is the one place a
        // real one gets built; tests pass nil.
        let handler = LocationHandler()
        _locationHandler = State(initialValue: handler)
        _contextDetector = State(initialValue: ContextDetector(poiProvider: handler,
                                                               weatherProvider: WeatherKitProvider()))
    }

    // MARK: - Container construction
    //
    // This used to fatalError, which meant a corrupt store, a full disk or a
    // migration that threw was an unrecoverable launch crash whose only user-
    // side fix was deleting the app — which deletes the library it was trying
    // to protect. Attaching a migration plan (SongMigrationPlan) added a fresh
    // way to throw here, so the crash got *more* likely, not less.
    //
    // Falling back to memory is a genuine trade, not a free win. The app
    // launches, but the library looks empty and nothing written survives the
    // quit. That is only better than crashing if the user is told, hence
    // storeHealth — see the @TODO on body.
    //
    // Note what this deliberately does NOT do: it doesn't delete or move the
    // failed store. Those bytes are the user's library, and a store today's
    // migration can't open may still be readable by a later build or by a
    // repair path we haven't written yet. Wiping it to get a clean launch
    // would be the app doing the exact thing we're trying to spare the user
    // from having to do by hand.
    private static func makeModelContainer() -> (ModelContainer, ModelStoreHealth) {
        let schema = Schema(versionedSchema: SongSchemaV4.self)

        do {
            let onDisk = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema,
                                               migrationPlan: SongMigrationPlan.self,
                                               configurations: [onDisk])
            return (container, .onDisk)
        } catch {
            print("Could not open the on-disk model store, falling back to memory: \(error)")

            do {
                // no migration plan on this one. An in-memory store is created
                // empty on every launch, so there is never anything to migrate
                // — running the plan here would only re-introduce the failure
                // mode we're recovering from.
                let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                let container = try ModelContainer(for: schema, configurations: [inMemory])
                return (container, .inMemory(reason: String(describing: error)))
            } catch {
                // Deliberately still fatal. An empty in-memory container needs
                // no file, no disk space and no migration — if the schema
                // itself can't be realised then every screen is a @Query over
                // models that don't exist, and there is no degraded mode left
                // to fall back to. Crashing here is honest; limping isn't an
                // option.
                fatalError("Could not create an in-memory ModelContainer either: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Both types are still ObservableObject, so this is
                // .environmentObject rather than .environment — the
                // single-argument .environment(_:) needs Observable
                // conformance, which the @Observable macro provides and
                // ObservableObject does not.
                // @TODO: collapse these two into .environment(...) as part of
                // the @Observable migration (LR-19).
                .environmentObject(locationHandler)
                .environmentObject(contextDetector)
                // @TODO: nothing reads this yet, and that's the unfinished
                // half of LR-10 — a degraded launch currently looks exactly
                // like a first launch with an empty library, which is the
                // dangerous part. Surface it in ContentView as a persistent
                // banner (not a dismissible alert; the condition lasts the
                // whole session) saying the library couldn't be opened and
                // that changes won't be saved. That's a view change in
                // LR-30b's files, so it isn't done here.
                .environment(\.modelStoreHealth, storeHealth)
        }
        .modelContainer(sharedModelContainer)
    }
}
