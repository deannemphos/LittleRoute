import SwiftUI
import MapKit

struct MapView: View {
    let contextDetector: ContextDetector
    var context: MusicContext
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedPlace: ContextClassifier.Zone?

    var body: some View {
        Map(position: $position) {
            if let snapshot = contextDetector.snapshot {
                ForEach(snapshot.regions) { region in
                    let active = region.context == contextDetector.geographicContext
                    let pending = region.context == contextDetector.candidateContext && !active
                    MapPolygon(region.polygon)
                        .foregroundStyle(region.context.tintColor.opacity(active ? 0.25 : 0.09))
                        .stroke(region.context.tintColor.opacity(active || pending ? 0.95 : 0.5),
                                style: StrokeStyle(lineWidth: active ? 3 : (pending ? 2 : 1),
                                                   dash: pending ? [6, 4] : []))
                }
            }
            ForEach(Array(contextDetector.zones.sorted { $0.score > $1.score }.prefix(8))) { zone in
                Annotation(zone.name, coordinate: zone.coordinate) {
                    Button { selectedPlace = zone } label: {
                        Image(systemName: zone.context.iconName)
                            .font(.caption.bold()).padding(6)
                            .foregroundStyle(.white).background(zone.context.tintColor, in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("\(zone.name), \(zone.context.displayName)")
                }
            }
            UserAnnotation()
        }
        .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
        .accessibilityLabel("Nearby music zones. Solid outline marks your area; dashed outline marks a candidate.")
        .sheet(item: $selectedPlace) { zone in
            NavigationStack {
                VStack(spacing: 16) {
                    Label(zone.name, systemImage: zone.context.iconName).font(.title2)
                    Text(zone.context.displayName).font(.headline)
                    Text("This place contributes to the weighted music zones. The polygons are inferred listening areas, not property boundaries.")
                    Text(contextDetector.status)
                }
                .padding()
                .toolbar { Button("Done") { selectedPlace = nil } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

struct ContextStatusView: View {
    let contextDetector: ContextDetector
    let audioManager: AudioPlayerManager

    var body: some View {
        VStack(spacing: 6) {
            Text(contextDetector.status).font(.callout.weight(.semibold))
                .accessibilityIdentifier("contextStatus")
            if contextDetector.musicReason != "Location" {
                Text("Music reason: \(contextDetector.musicReason)").font(.caption)
            }
            if audioManager.queueSource != audioManager.currentContext, !audioManager.songQueue.isEmpty {
                Text("Playing All songs: no songs tagged \(audioManager.currentContext.displayName).").font(.caption)
            }
            if let distance = contextDetector.boundaryDistance {
                Text("Nearest boundary: about \(distance, format: .number.precision(.fractionLength(0))) m").font(.caption)
            }
            if let error = contextDetector.searchError { Text(error).font(.callout) }
            if let weather = contextDetector.weatherStatus { Text(weather).font(.caption) }
            if let candidate = contextDetector.candidateContext {
                Button("Switch Now to \(candidate.displayName)") { contextDetector.switchNow() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .disabled(!contextDetector.canSwitchNow)
            }
        }
        .multilineTextAlignment(.center)
    }
}

struct ExpandedContextMap: View {
    let contextDetector: ContextDetector
    let audioManager: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var showNearby = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapView(contextDetector: contextDetector, context: audioManager.currentContext)
                    .accessibilityIdentifier("expandedContextMap")
                ScrollView {
                    ContextStatusView(contextDetector: contextDetector, audioManager: audioManager)
                    Text("Solid: your area. Dashed: entering. Crossing starts confirmation, not an immediate switch. Unshaded ground outside loaded zones is unknown.")
                        .font(.caption).padding(.vertical, 8)
                    DisclosureGroup("Nearby places", isExpanded: $showNearby) {
                        ForEach(contextDetector.zones) { zone in
                            Label("\(zone.name) - \(zone.context.displayName)", systemImage: zone.context.iconName)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }
                    }
                    HStack {
                        Text(audioManager.currentSong?.title ?? "No song playing").lineLimit(2)
                        Spacer()
                        Button { audioManager.musicPlayPause() } label: {
                            Image(systemName: audioManager.isPaused ? "play.fill" : "pause.fill")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(audioManager.isPaused ? "Play" : "Pause")
                    }
                }
                .padding().frame(maxHeight: 240)
            }
            .navigationTitle("Music Zones").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { contextDetector.refreshNow() }.disabled(contextDetector.isSearching)
                }
            }
        }
    }
}
