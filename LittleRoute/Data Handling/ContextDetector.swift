import Foundation
import CoreLocation
import MapKit

// Dwell-based area/context detection.
//
// Polls nearby POIs on a timer and classifies them via ContextClassifier.
// A new context only becomes "confirmed" after it has been continuously
// observed for `dwellDuration` — this avoids music flapping when walking
// along the boundary of two areas. When no mappable POI is observed for a
// full dwell window, falls back to the generic .traveling context.
class ContextDetector: ObservableObject {

    // MARK: - Configuration
    let pollInterval: TimeInterval   // how often to query POIs (MKLocalSearch is rate-limited, keep this modest)
    let dwellDuration: TimeInterval  // how long a candidate context must persist before switching
    let searchRadius: CLLocationDistance

    // MARK: - State
    @Published private(set) var confirmedContext: AudioPlayerManager.Context
    private(set) var candidateContext: AudioPlayerManager.Context?
    private(set) var candidateSince: Date?

    // Fired on the main thread whenever a new context is confirmed
    var onContextChange: ((AudioPlayerManager.Context) -> Void)?

    private weak var locationHandler: LocationHandler?
    private var pollTimer: Timer?

    // Injectable clock for testability
    var now: () -> Date = { Date() }

    init(locationHandler: LocationHandler,
         initialContext: AudioPlayerManager.Context = .all,
         pollInterval: TimeInterval = 10,
         dwellDuration: TimeInterval = 30,
         searchRadius: CLLocationDistance = 100) {
        self.locationHandler = locationHandler
        self.confirmedContext = initialContext
        self.pollInterval = pollInterval
        self.dwellDuration = dwellDuration
        self.searchRadius = searchRadius
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle
    public func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll() // kick off an immediate first check
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Detection
    private func poll() {
        guard let locationHandler = locationHandler,
              locationHandler.currentLocation != nil else { return }

        locationHandler.getPointsOfInterest(radius: searchRadius) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let places):
                let observed = ContextClassifier.classify(
                    places: places,
                    userLocation: locationHandler.currentLocation
                )
                DispatchQueue.main.async {
                    self.process(observation: observed)
                }
            case .failure(let error):
                // Transient search failures shouldn't disturb the state machine
                print("ContextDetector POI search failed: \(error)")
            }
        }
    }

    // State machine: promote an observed context to confirmed only after it
    // has been observed continuously for dwellDuration. A nil observation
    // (no mappable POI nearby) is treated as a .traveling candidate.
    // Exposed as internal (not private) for unit testing.
    func process(observation: AudioPlayerManager.Context?) {
        let observedContext = observation ?? .traveling

        if observedContext == confirmedContext {
            // Still in the same area — drop any pending candidate
            candidateContext = nil
            candidateSince = nil
            return
        }

        if observedContext != candidateContext {
            // New candidate — restart the dwell clock
            candidateContext = observedContext
            candidateSince = now()
            return
        }

        // Same candidate as before — promote once the dwell window has elapsed
        if let since = candidateSince, now().timeIntervalSince(since) >= dwellDuration {
            confirmedContext = observedContext
            candidateContext = nil
            candidateSince = nil
            print("ContextDetector: switched context to \(observedContext.rawValue)")
            onContextChange?(observedContext)
        }
    }
}
