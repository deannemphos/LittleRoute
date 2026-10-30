import Foundation
import CoreLocation
import MapKit
import Observation
import os

protocol KeyValueStoring {
    func data(forKey defaultName: String) -> Data?
    func double(forKey defaultName: String) -> Double
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: KeyValueStoring {}

@MainActor
@Observable
final class ContextDetector {
    let minimumSearchInterval: TimeInterval
    let minimumSearchDisplacement: CLLocationDistance
    let dwellDuration: TimeInterval
    let searchRadius: CLLocationDistance
    let debtAccumulationDuration: TimeInterval
    let switchBufferDuration: TimeInterval
    let maximumRestoreAge: TimeInterval
    static let defaultDebtAccumulationDuration: TimeInterval = 480
    static let debtAccumulationDefaultsKey = "contextDebtAccumulationDuration"
    static let defaultMaximumRestoreAge: TimeInterval = 6 * 60 * 60
    static let stateDefaultsKey = "contextDetectorState"
    static let persistedStateVersion = 2
    private let coreRadius: Double = 300
    private let cacheLifetime: TimeInterval = 600

    private(set) var confirmedContext: MusicContext
    private(set) var geographicContext: MusicContext?
    private(set) var zones: [ContextClassifier.Zone] = []
    private(set) var snapshot: ContextZoneSnapshot?
    private(set) var contextScores: [MusicContext: Double] = [:]
    private(set) var latestWeather: ContextClassifier.Factors.Condition?
    private(set) var debts: [MusicContext: Double] = [:]
    private(set) var varietyEnabled: Bool
    private(set) var isSearching = false
    private(set) var status = "Waiting for a reliable location."
    private(set) var musicReason = "Location"
    private(set) var searchError: String?
    private(set) var weatherStatus: String?
    private(set) var boundaryDistance: Double?
    private(set) var bufferedContext: MusicContext?
    private(set) var bufferExpiry: Date?
    private var transition: ContextTransitionState

    var candidateContext: MusicContext? { transition.candidate.flatMap(MusicContext.init(storageKey:)) }
    var candidateSince: Date? { transition.candidateSince }
    var canSwitchNow: Bool {
        candidateContext != nil && poiProvider?.currentLocation.map(isUsable) == true &&
            (snapshot.map { now().timeIntervalSince($0.generatedAt) <= cacheLifetime } == true || highSpeed)
    }

    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var onContextChange: ((MusicContext) -> Void)?
    @ObservationIgnored private weak var poiProvider: (any POIProviding)?
    @ObservationIgnored private let weatherProvider: (any WeatherProviding)?
    @ObservationIgnored private let store: any KeyValueStoring
    @ObservationIgnored private var running = false
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var lastSearchStarted: Date?
    @ObservationIgnored private var lastSearchLocation: CLLocation?
    @ObservationIgnored private var lastSearchSucceeded: Date?
    @ObservationIgnored private var lastValidLocation: CLLocation?
    @ObservationIgnored private var lastProcessedFix: Date?
    @ObservationIgnored private var lastSpeedLocation: CLLocation?
    @ObservationIgnored private var lastDebtTick: Date?
    @ObservationIgnored private var projection: ZoneProjection?
    @ObservationIgnored private var requestGeneration = 0
    @ObservationIgnored private var geometryGeneration = 0
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var nextSearchAttempt = Date.distantPast
    @ObservationIgnored private var searchFailures = 0
    @ObservationIgnored private var highSpeed = false
    @ObservationIgnored private var lastDebtFreeWinner: MusicContext?
    @ObservationIgnored private var geometryWorker: Task<ContextZoneGeometry, Error>?
    @ObservationIgnored private var geometryTask: Task<Void, Never>?
    @ObservationIgnored private var cache: [CachedRegion] = []

    private struct CachedRegion {
        let location: CLLocation
        let fetchedAt: Date
        let zones: [ContextClassifier.Zone]
    }

    init(poiProvider: any POIProviding, initialContext: MusicContext = .all,
         minimumSearchInterval: TimeInterval = 10,
         minimumSearchDisplacement: CLLocationDistance = 50,
         dwellDuration: TimeInterval = 30,
         searchRadius: CLLocationDistance = ContextClassifier.searchRadius + 450,
         debtAccumulationDuration: TimeInterval? = nil,
         switchBufferDuration: TimeInterval = 180,
         maximumRestoreAge: TimeInterval = ContextDetector.defaultMaximumRestoreAge,
         minimumResidenceDuration: TimeInterval = 90,
         maximumEvidenceGap: TimeInterval = 15,
         minimumEvidenceSamples: Int = 3,
         varietyEnabled: Bool = false,
         store: any KeyValueStoring = UserDefaults.standard,
         weatherProvider: (any WeatherProviding)?) {
        self.poiProvider = poiProvider
        self.confirmedContext = initialContext
        self.minimumSearchInterval = minimumSearchInterval
        self.minimumSearchDisplacement = minimumSearchDisplacement
        self.dwellDuration = dwellDuration
        self.searchRadius = searchRadius
        let storedDuration = store.double(forKey: Self.debtAccumulationDefaultsKey)
        let duration = debtAccumulationDuration ?? (storedDuration > 0 ? storedDuration : Self.defaultDebtAccumulationDuration)
        self.debtAccumulationDuration = duration > 0 ? duration : Self.defaultDebtAccumulationDuration
        self.switchBufferDuration = switchBufferDuration
        self.maximumRestoreAge = maximumRestoreAge
        self.varietyEnabled = varietyEnabled
        self.store = store
        self.weatherProvider = weatherProvider
        transition = ContextTransitionState(dwell: dwellDuration, residence: minimumResidenceDuration,
                                            maximumGap: maximumEvidenceGap, minimumSamples: minimumEvidenceSamples)
    }

    func start() {
        guard !running else { return }
        running = true
        if !restored {
            restored = true
            restoreState()
        }
        poiProvider?.onLocationUpdate = { [weak self] _ in self?.evaluate() }
        evaluate()
    }

    func stop() {
        running = false
        requestGeneration += 1
        geometryGeneration += 1
        poiProvider?.onLocationUpdate = nil
        poiProvider?.cancelSearch()
        geometryWorker?.cancel()
        geometryTask?.cancel()
        isSearching = false
        pendingRefresh = false
        transition.resetCandidate()
    }

    func setVarietyEnabled(_ enabled: Bool) {
        guard varietyEnabled != enabled else { return }
        varietyEnabled = enabled
        debts = [:]
        lastDebtTick = nil
        clearBuffer()
        transition.resetCandidate()
        status = enabled ? "Variety enabled. Changes still need stable evidence." : "Stable mode. Following geographic zones."
        persistState()
    }

    /// Refresh data, not playback. All search starts share the same rate limit.
    func refreshNow() {
        pendingRefresh = true
        status = "Refresh queued; keeping the current music."
        evaluate()
    }

    func switchNow() {
        guard canSwitchNow, let candidate = candidateContext else {
            status = "A reliable candidate is needed before switching."
            return
        }
        clearBuffer()
        confirm(candidate, debtFreeWinner: lastDebtFreeWinner)
    }

    func waitForPendingGeometry() async {
        await geometryTask?.value
    }

    private func isUsable(_ location: CLLocation) -> Bool {
        let age = now().timeIntervalSince(location.timestamp)
        return CLLocationCoordinate2DIsValid(location.coordinate) &&
            abs(location.coordinate.latitude) < 85 &&
            location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0 &&
            location.horizontalAccuracy <= 50 && age >= -1 && age <= 15
    }

    private func evaluate() {
        guard running, let provider = poiProvider, let location = provider.currentLocation,
              isUsable(location) else {
            transition.resetCandidate()
            status = "Location uncertain. Keeping the current music."
            return
        }
        if let previous = lastValidLocation, location.timestamp < previous.timestamp { return }
        lastValidLocation = location
        apply(location)
        let clock = now()
        let moved = lastSearchLocation.map { location.distance(from: $0) >= minimumSearchDisplacement } ?? true
        let expired = lastSearchSucceeded.map { clock.timeIntervalSince($0) >= cacheLifetime } ?? true
        guard pendingRefresh || moved || expired else { return }
        guard !isSearching, clock >= nextSearchAttempt,
              lastSearchStarted.map({ clock.timeIntervalSince($0) >= minimumSearchInterval }) ?? true else { return }
        isSearching = true
        pendingRefresh = false
        lastSearchStarted = clock
        requestGeneration += 1
        let generation = requestGeneration
        let interval = Log.poiSearch.beginInterval("POI Search", id: Log.poiSearch.makeSignpostID())
        provider.getPointsOfInterest(radius: searchRadius, filter: Array(ContextClassifier.categoryMap.keys)) { [weak self] result in
            Log.poiSearch.endInterval("POI Search", interval)
            guard let self, self.running, generation == self.requestGeneration else { return }
            self.isSearching = false
            switch result {
            case .success(let places):
                self.searchFailures = 0
                self.searchError = nil
                self.lastSearchLocation = location
                self.lastSearchSucceeded = self.now()
                let discovered = ContextClassifier.evaluate(places: places, userLocation: location).zones
                self.cache.removeAll { self.now().timeIntervalSince($0.fetchedAt) >= self.cacheLifetime ||
                    location.distance(from: $0.location) > 3_000 }
                self.cache.append(CachedRegion(location: location, fetchedAt: self.now(), zones: discovered))
                if self.cache.count > 9 { self.cache.removeFirst(self.cache.count - 9) }
                self.rebuildGeometry(around: location)
            case .failure:
                self.searchFailures += 1
                self.nextSearchAttempt = self.now().addingTimeInterval(min(120, 10 * pow(2, Double(min(self.searchFailures - 1, 4)))))
                self.searchError = "Nearby zones could not be refreshed. Keeping available music and retrying."
                Log.context.error("Nearby zone search failed; retaining the previous snapshot")
            }
        }
    }

    private func rebuildGeometry(around location: CLLocation) {
        if projection == nil || snapshot.map({ hypot($0.point(for: location).x, $0.point(for: location).y) > 5_000 }) == true {
            projection = ZoneProjection(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        }
        guard let projection else { return }
        let center = projection.point(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        // The circular search includes the square core's corners plus every
        // profile's maximum influence radius. Unsearched ground stays unknown.
        let radius = min(coreRadius, max(0, (searchRadius - ContextClassifier.searchRadius) / sqrt(2)) - 10)
        guard radius > 0 else {
            searchError = "The search area is too small to establish reliable zone boundaries."
            Log.context.error("Zone coverage is missing its influence halo")
            return
        }
        var records: [String: ContextClassifier.Zone] = [:]
        for region in cache {
            for zone in region.zones { records[zone.id] = zone }
        }
        let nearby = records.values.sorted { $0.id < $1.id }.filter { zone in
            let point = projection.point(latitude: zone.coordinate.latitude, longitude: zone.coordinate.longitude)
            return abs(point.x - center.x) <= radius + zone.radius &&
                abs(point.y - center.y) <= radius + zone.radius
        }
        let sites = nearby.compactMap { zone -> ContextZoneGeometry.Site? in
            guard let profile = ContextClassifier.profile(for: zone.context) else { return nil }
            return .init(id: zone.id,
                         point: projection.point(latitude: zone.coordinate.latitude, longitude: zone.coordinate.longitude),
                         context: zone.context.storageKey, radius: profile.effectiveRadius, specificity: profile.specificity)
        }
        let bounds = ContextZoneGeometry.Bounds(minX: center.x - radius, minY: center.y - radius,
                                                maxX: center.x + radius, maxY: center.y + radius)
        geometryGeneration += 1
        let generation = geometryGeneration
        geometryWorker?.cancel()
        geometryTask?.cancel()
        let interval = Log.zoneGeometry.beginInterval("Build Zones", id: Log.zoneGeometry.makeSignpostID())
        let worker = Task.detached(priority: .utility) { try ContextZoneGeometry.build(sites: sites, bounds: bounds) }
        geometryWorker = worker
        geometryTask = Task { @MainActor [weak self] in
            defer { Log.zoneGeometry.endInterval("Build Zones", interval) }
            do {
                let geometry = try await worker.value
                guard let self, !Task.isCancelled, self.running, self.geometryGeneration == generation else { return }
                let previous = self.lastValidLocation.flatMap { self.snapshot?.geometry.context(at: self.snapshot!.point(for: $0)) }
                self.snapshot = ContextZoneSnapshot(geometry: geometry, projection: projection, generatedAt: self.now())
                self.zones = nearby
                if let current = self.lastValidLocation, self.isUsable(current) {
                    if previous != geometry.context(at: self.snapshot!.point(for: current)) {
                        self.transition.resetCandidate()
                        self.lastProcessedFix = nil
                    }
                    self.apply(current)
                }
            } catch is CancellationError {
                // Superseded geometry has no authority to publish.
            } catch {
                guard let self, generation == self.geometryGeneration else { return }
                self.searchError = error.localizedDescription
                Log.context.error("Zone geometry could not be generated")
            }
        }
    }

    private func apply(_ location: CLLocation) {
        guard lastProcessedFix.map({ location.timestamp > $0 }) ?? true else { return }
        let speed: Double?
        if location.speed.isFinite, location.speed >= 0 {
            speed = location.speed
        } else if let previous = lastSpeedLocation, location.timestamp > previous.timestamp {
            let distance = max(0, location.distance(from: previous) - max(location.horizontalAccuracy, previous.horizontalAccuracy))
            speed = distance / location.timestamp.timeIntervalSince(previous.timestamp)
        } else {
            speed = nil
        }
        lastSpeedLocation = location
        if let speed { highSpeed = speed > (highSpeed ? 30 * 0.44704 : ContextClassifier.travelingSpeedThreshold) }
        else { highSpeed = false }

        if !highSpeed {
            weatherProvider?.currentCondition(at: location) { [weak self] condition in
                self?.latestWeather = condition
                self?.weatherStatus = condition == nil ? "Weather unavailable; using location." : nil
            }
        }
        var baseScores: [MusicContext: Double] = [:]
        var geographic: MusicContext?
        if let snapshot, now().timeIntervalSince(snapshot.generatedAt) <= cacheLifetime {
            let point = snapshot.point(for: location)
            if let scores = snapshot.geometry.scores(at: point) {
                baseScores = Dictionary(uniqueKeysWithValues: scores.compactMap { key, value in
                    MusicContext(storageKey: key).map { ($0, value) }
                })
                geographic = snapshot.geometry.context(at: point).flatMap(MusicContext.init(storageKey:))
                boundaryDistance = geographic.map { snapshot.geometry.inwardDistance(at: point, context: $0.storageKey) }
            }
        }
        geographicContext = geographic
        guard geographic != nil || highSpeed else {
            transition.resetCandidate()
            boundaryDistance = nil
            status = "Loading nearby zones. Keeping the current music."
            return
        }
        let uninterrupted = lastProcessedFix.map { location.timestamp.timeIntervalSince($0) <= 15 } ?? false
        lastProcessedFix = location.timestamp
        tickDebt(isMoving: uninterrupted && (speed ?? 0) >= 0.5)
        let weatherScores = ContextClassifier.applyWeather(to: baseScores, condition: highSpeed ? nil : latestWeather)
        let debtFree = highSpeed ? MusicContext.traveling : (ContextClassifier.winner(of: weatherScores) ?? .traveling)
        contextScores = Dictionary(uniqueKeysWithValues: weatherScores.map { context, score in
            (context, score * ContextClassifier.debtMultiplier(for: varietyEnabled ? debt(for: context) : 0))
        })
        let observed = highSpeed ? MusicContext.traveling : (ContextClassifier.winner(of: contextScores) ?? .traveling)
        lastDebtFreeWinner = debtFree
        musicReason = highSpeed ? "High-speed travel" :
            (varietyEnabled && observed != debtFree ? "Variety" :
                (debtFree != geographic ? "Weather adjustment" : (geographic == .traveling ? "No nearby place" : "Location")))
        let modifier = highSpeed || observed != geographic
        let eligible = modifier || (boundaryDistance ?? 0) > max(25, location.horizontalAccuracy)
        process(observation: observed, observationIgnoringDebt: debtFree, evidenceAt: location.timestamp, eligible: eligible)
        if !eligible, observed != confirmedContext {
            status = "Near \(observed.displayName). Move farther inside to change music."
        }
    }

    func process(observation: MusicContext?, observationIgnoringDebt: MusicContext? = nil,
                 evidenceAt: Date? = nil, eligible: Bool = true) {
        defer { persistState() }
        let observed = observation ?? .traveling
        if let expiry = bufferExpiry, now() >= expiry { clearBuffer() }
        if observed == bufferedContext {
            transition.resetCandidate()
            status = "Keeping \(confirmedContext.displayName) briefly."
            return
        }
        if transition.observe(observed.storageKey, confirmed: confirmedContext.storageKey,
                              at: evidenceAt ?? now(), eligible: eligible) {
            confirm(observed, debtFreeWinner: observationIgnoringDebt ?? observation)
        } else if candidateContext != nil {
            status = transition.remainingResidence(at: now()) > 0
                ? "Entering \(observed.displayName). Keeping \(confirmedContext.displayName) briefly."
                : "Entering \(observed.displayName). Confirming location."
        } else if observed == confirmedContext {
            status = "In \(geographicContext?.displayName ?? observed.displayName)"
        }
    }

    private func confirm(_ context: MusicContext, debtFreeWinner: MusicContext?) {
        if varietyEnabled, debtFreeWinner == confirmedContext {
            bufferedContext = confirmedContext
            bufferExpiry = now().addingTimeInterval(switchBufferDuration)
        }
        confirmedContext = context
        transition.confirm(at: now())
        status = "Music: \(context.displayName)"
        persistState()
        Log.context.notice("Confirmed music context: \(context.storageKey, privacy: .public)")
        onContextChange?(context)
    }

    func tickDebt(isMoving: Bool) {
        let clock = now()
        defer { lastDebtTick = clock; persistState() }
        guard varietyEnabled else {
            if !debts.isEmpty { debts = [:] }
            return
        }
        guard let previous = lastDebtTick else { return }
        let elapsed = clock.timeIntervalSince(previous)
        guard elapsed > 0 else { return }
        let delta = ContextClassifier.maxDebt * elapsed / debtAccumulationDuration
        var balances = debts
        for context in Set(balances.keys).union([confirmedContext]) {
            let balance = (balances[context] ?? 0) + (isMoving && context == confirmedContext ? delta : -delta)
            balances[context] = min(ContextClassifier.maxDebt, max(0, balance))
        }
        debts = balances.filter { $0.value > 0 }
        if let bufferedContext, debts[bufferedContext] == nil { clearBuffer() }
    }

    func debt(for context: MusicContext) -> Double { debts[context] ?? 0 }

    private func clearBuffer() {
        bufferedContext = nil
        bufferExpiry = nil
    }

    private struct PersistedState: Codable {
        let version: Int
        let confirmedContext: String
        let debts: [String: Double]
        let bufferedContext: String?
        let bufferExpiry: Date?
        let savedAt: Date
        let varietyEnabled: Bool?
        let lastConfirmedAt: Date?
    }

    private func persistState() {
        let state = PersistedState(version: Self.persistedStateVersion, confirmedContext: confirmedContext.storageKey,
                                   debts: Dictionary(uniqueKeysWithValues: debts.map { ($0.key.storageKey, $0.value) }),
                                   bufferedContext: bufferedContext?.storageKey, bufferExpiry: bufferExpiry, savedAt: now(),
                                   varietyEnabled: varietyEnabled, lastConfirmedAt: transition.lastConfirmedAt)
        do {
            store.set(try JSONEncoder().encode(state), forKey: Self.stateDefaultsKey)
        } catch {
            Log.context.error("Context state could not be saved")
        }
    }

    private func restoreState() {
        guard let data = store.data(forKey: Self.stateDefaultsKey) else { return }
        do {
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            let age = now().timeIntervalSince(state.savedAt)
            guard (1...Self.persistedStateVersion).contains(state.version), age >= 0, age <= maximumRestoreAge else {
                store.removeObject(forKey: Self.stateDefaultsKey)
                return
            }
            confirmedContext = MusicContext(storageKey: state.confirmedContext) ?? confirmedContext
            varietyEnabled = state.version >= 2 ? (state.varietyEnabled ?? false) : false
            if let confirmedAt = state.lastConfirmedAt, confirmedAt <= now() { transition.confirm(at: confirmedAt) }
            if varietyEnabled {
                debts = Dictionary(uniqueKeysWithValues: state.debts.compactMap { key, value in
                    guard let context = MusicContext(storageKey: key), value.isFinite, value > 0 else { return nil }
                    return (context, min(value, ContextClassifier.maxDebt))
                })
                if let key = state.bufferedContext, let expiry = state.bufferExpiry, expiry > now() {
                    bufferedContext = MusicContext(storageKey: key)
                    bufferExpiry = expiry
                }
                lastDebtTick = state.savedAt
                tickDebt(isMoving: false)
            }
            status = "Restored music. Waiting for a reliable location."
        } catch {
            store.removeObject(forKey: Self.stateDefaultsKey)
            Log.context.notice("Discarded incompatible context state")
        }
    }
}
