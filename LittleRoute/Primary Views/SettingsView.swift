import SwiftUI
import MapKit

struct SettingsView: View {
    let contextDetector: ContextDetector
    let locationHandler: LocationHandler

    var body: some View {
        TabView {
            EqualizerSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
            CustomPlacesView(contextDetector: contextDetector, locationHandler: locationHandler)
                .tabItem { Label("Places", systemImage: "mappin.and.ellipse") }
        }
    }
}

private struct EqualizerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let graph = AudioGraph.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(graph.gains.indices, id: \.self) { band in
                        bandRow(band)
                    }
                    Button("Reset Equalizer") { graph.resetGains() }
                        .disabled(graph.gains.allSatisfy { $0 == 0 })
                } header: {
                    Text("Equalizer")
                } footer: {
                    Text("Applies to everything LittleRoute plays.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
    }

    private func bandRow(_ band: Int) -> some View {
        let frequency = AudioGraph.bandFrequencies[band]
        let name = frequency >= 1_000 ? "\(Int(frequency / 1_000)) kHz" : "\(Int(frequency)) Hz"
        let gain = Int(graph.gains[band])
        return HStack {
            Text(name).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { graph.gains[band] }, set: { graph.setGain($0, band: band) }),
                   in: AudioGraph.gainRange, step: 1)
                .accessibilityLabel("\(name) gain")
                .accessibilityValue("\(gain) decibels")
            Text("\(gain > 0 ? "+" : "")\(gain) dB")
                .font(.callout.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

private struct CustomPlacesView: View {
    let contextDetector: ContextDetector
    let locationHandler: LocationHandler
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(contextDetector.customPlaces) { place in
                    let context = MusicContext(storageKey: place.contextKey)
                    Label {
                        VStack(alignment: .leading) {
                            Text(place.name)
                            Text("\(context?.displayName ?? place.contextKey), \(Int(place.radius)) m")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: context?.iconName ?? "mappin")
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { contextDetector.customPlaces[$0].id }
                    for id in ids { contextDetector.removeCustomPlace(id: id) }
                }
            }
            .overlay {
                if contextDetector.customPlaces.isEmpty {
                    ContentUnavailableView("No Custom Places", systemImage: "mappin.slash",
                                           description: Text("Add a place, such as your home or office, and choose the music it should play."))
                }
            }
            .navigationTitle("My Places")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Place", systemImage: "plus") { isAdding = true }
                        .accessibilityIdentifier("addCustomPlace")
                }
            }
            .sheet(isPresented: $isAdding) {
                AddPlaceView(currentLocation: locationHandler.currentLocation?.coordinate,
                             onSave: { contextDetector.addCustomPlace($0) })
            }
        }
    }
}

private struct AddPlaceView: View {
    let currentLocation: CLLocationCoordinate2D?
    let onSave: (CustomPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var context = MusicContext.home
    @State private var radius = CustomPlace.defaultRadius
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    private var place: CustomPlace? {
        coordinate.flatMap {
            CustomPlace(name: name, latitude: $0.latitude, longitude: $0.longitude,
                        contextKey: context.storageKey, radius: radius)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Music", selection: $context) {
                    ForEach(ContextDetector.customPlaceContexts, id: \.self) { context in
                        Text(context.displayName).tag(context)
                    }
                }
                Stepper("Radius: \(Int(radius)) m", value: $radius, in: CustomPlace.radiusRange, step: 25)
                Section {
                    MapReader { proxy in
                        Map(position: $position) {
                            UserAnnotation()
                            if let coordinate {
                                Marker(name.isEmpty ? "New place" : name, coordinate: coordinate)
                                MapCircle(center: coordinate, radius: radius)
                                    .foregroundStyle(Color.accentColor.opacity(0.2))
                            }
                        }
                        .onTapGesture { point in
                            if let tapped = proxy.convert(point, from: .local) { coordinate = tapped }
                        }
                    }
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                    .accessibilityLabel("Map. Tap to move the pin.")
                    Button("Use Current Location") { coordinate = currentLocation }
                        .disabled(currentLocation == nil)
                } footer: {
                    Text("Tap the map to move the pin. Music changes after you have been inside the circle for a little while.")
                }
            }
            .navigationTitle("Add Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let place { onSave(place) }
                        dismiss()
                    }
                    .disabled(place == nil)
                }
            }
            .onAppear { if coordinate == nil { coordinate = currentLocation } }
        }
    }
}
