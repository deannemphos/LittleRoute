//
//  LittleRouteApp.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 12/4/24.
//

import SwiftUI
import SwiftData

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

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
            Song.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
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
        }
        .modelContainer(sharedModelContainer)
    }
}
