import AVFoundation
import Observation
import os

/// The slice of AVAudioPlayer that AudioPlayerManager drives. AVAudioPlayer has
/// no hook for an equalizer or a spectrum tap, so the app plays through
/// EnginePlayer; the tests keep injecting real AVAudioPlayers.
@MainActor
protocol SongPlayer: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var volume: Float { get set }
    var isPlaying: Bool { get }
    @discardableResult func prepareToPlay() -> Bool
    @discardableResult func play() -> Bool
    func pause()
    func stop()
    func setVolume(_ volume: Float, fadeDuration: TimeInterval)
}

extension AVAudioPlayer: SongPlayer {}

/// The one audio engine: players -> mixer -> equalizer -> output. Also owns the
/// equalizer gains and the visualizer's band levels.
@MainActor
@Observable
final class AudioGraph {
    static let shared = AudioGraph()
    static let bandFrequencies: [Float] = [60, 250, 1_000, 4_000, 12_000]
    static let gainRange: ClosedRange<Float> = -12...12
    static let gainsDefaultsKey = "equalizerGains"

    private(set) var gains: [Float]
    private(set) var levels = [Float](repeating: 0, count: Spectrum.bandCount)

    @ObservationIgnored private var nodes: (engine: AVAudioEngine, input: AVAudioMixerNode, eq: AVAudioUnitEQ)?
    @ObservationIgnored private var visualizing = false
    @ObservationIgnored private var players = 0

    private init() {
        let saved = UserDefaults.standard.array(forKey: Self.gainsDefaultsKey) as? [Double] ?? []
        gains = Self.bandFrequencies.indices.map { $0 < saved.count ? Self.clamp(Float(saved[$0])) : 0 }
    }

    private static func clamp(_ gain: Float) -> Float {
        gain.isFinite ? min(max(gain, gainRange.lowerBound), gainRange.upperBound) : 0
    }

    // A fixed format keeps the equalizer and its tap valid across route changes;
    // the engine's own output mixer converts to whatever the hardware wants.
    private static var format: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
    }

    // MARK: Equalizer

    func setGain(_ gain: Float, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = Self.clamp(gain)
        nodes?.eq.bands[band].gain = gains[band]
        UserDefaults.standard.set(gains.map(Double.init), forKey: Self.gainsDefaultsKey)
    }

    func resetGains() {
        for band in gains.indices { setGain(0, band: band) }
    }

    // MARK: Engine

    var engine: AVAudioEngine? { nodes?.engine }

    /// Built on first playback, so tests and previews never open audio hardware.
    private func graph() -> (engine: AVAudioEngine, input: AVAudioMixerNode, eq: AVAudioUnitEQ) {
        if let nodes { return nodes }
        let engine = AVAudioEngine()
        let input = AVAudioMixerNode()
        let eq = AVAudioUnitEQ(numberOfBands: Self.bandFrequencies.count)
        for (index, band) in eq.bands.enumerated() {
            band.filterType = index == 0 ? .lowShelf : (index == eq.bands.count - 1 ? .highShelf : .parametric)
            band.frequency = Self.bandFrequencies[index]
            band.bandwidth = 2 // octaves; the bands sit two octaves apart
            band.gain = gains[index]
            band.bypass = false // bands are bypassed by default
        }
        engine.attach(input)
        engine.attach(eq)
        engine.connect(input, to: eq, format: Self.format)
        engine.connect(eq, to: engine.mainMixerNode, format: Self.format)
        let built = (engine: engine, input: input, eq: eq)
        nodes = built
        if visualizing { installTap(on: eq) }
        return built
    }

    func attach(_ node: AVAudioPlayerNode, format: AVAudioFormat) {
        let built = graph()
        built.engine.attach(node)
        built.engine.connect(node, to: built.input, format: format)
        players += 1
    }

    func detach(_ node: AVAudioPlayerNode) {
        guard let nodes, node.engine === nodes.engine else { return }
        nodes.engine.detach(node)
        players -= 1
        // An idle engine keeps the audio session busy and cannot be deactivated.
        if players == 0 { nodes.engine.stop() }
    }

    func start() -> Bool {
        guard let nodes else { return false }
        if nodes.engine.isRunning { return true }
        do {
            try nodes.engine.start()
            return true
        } catch {
            Log.playback.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func pause() {
        nodes?.engine.pause()
    }

    // MARK: Visualizer

    func setVisualizing(_ on: Bool) {
        guard on != visualizing else { return }
        visualizing = on
        if let eq = nodes?.eq {
            if on { installTap(on: eq) } else { eq.removeTap(onBus: 0) }
        }
        if !on { levels = [Float](repeating: 0, count: Spectrum.bandCount) }
    }

    private func installTap(on eq: AVAudioUnitEQ) {
        eq.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Spectrum.window), format: Self.format,
                      block: Self.makeTapBlock())
    }

    // Built outside the main actor: the engine calls this on its own queue.
    nonisolated private static func makeTapBlock() -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            let levels = Spectrum.levels(samples: samples.suffix(Spectrum.window),
                                         sampleRate: buffer.format.sampleRate)
            Task { @MainActor in AudioGraph.shared.publish(levels) }
        }
    }

    private func publish(_ levels: [Float]) {
        if visualizing { self.levels = levels }
    }
}

/// One song on the shared engine. `stop()` is terminal, as AudioPlayerManager
/// already treats it: a stopped player is detached and never reused.
@MainActor
final class EnginePlayer: SongPlayer {
    let duration: TimeInterval
    private(set) var isPlaying = false
    /// true: the song played to its end. false: playback could not continue.
    var onFinish: ((Bool) -> Void)?

    private let node = AVAudioPlayerNode()
    private let file: AVAudioFile
    private let sampleRate: Double
    private var startTime: TimeInterval = 0 // where the current schedule began
    private var lastTime: TimeInterval = 0  // newest known position; outlives a stopped engine
    private var scheduleID = 0              // retires completions from superseded schedules
    private var attached = false
    private var fade: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        sampleRate = file.processingFormat.sampleRate
        guard file.length > 0, sampleRate > 0 else { throw CocoaError(.fileReadCorruptFile) }
        duration = Double(file.length) / sampleRate
    }

    func prepareToPlay() -> Bool {
        guard !attached else { return true }
        AudioGraph.shared.attach(node, format: file.processingFormat)
        attached = true
        // A route or sample-rate change stops the engine underneath us.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: AudioGraph.shared.engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartIfPlaying() }
        }
        return true
    }

    // Every start reschedules from the remembered position, so a pause, a seek,
    // an interruption and a stopped engine all resume the same way.
    func play() -> Bool {
        guard attached else { return false }
        if isPlaying { return true }
        node.stop() // also resets the node's sample clock to zero
        scheduleID += 1
        let first = min(AVAudioFramePosition(lastTime * sampleRate), file.length - 1)
        startTime = Double(first) / sampleRate
        node.scheduleSegment(file, startingFrame: first,
                             frameCount: AVAudioFrameCount(clamping: file.length - first), at: nil,
                             completionCallbackType: .dataPlayedBack,
                             completionHandler: Self.completion(for: self, schedule: scheduleID))
        // Starting a node on a stopped engine raises an Objective-C exception.
        guard AudioGraph.shared.start() else {
            node.stop()
            return false
        }
        node.play()
        isPlaying = true
        return true
    }

    // Built outside the main actor: the engine calls this on its own queue,
    // both when the audio runs out and when the node is stopped early.
    nonisolated private static func completion(for player: EnginePlayer,
                                               schedule: Int) -> AVAudioPlayerNodeCompletionHandler {
        { [weak player] _ in
            Task { @MainActor [weak player] in player?.finished(schedule: schedule) }
        }
    }

    private func finished(schedule: Int) {
        // An interruption or route change stops the engine before its handler
        // reaches the main queue, so a completion from that stop can arrive
        // while the schedule is still current. Only a completion with the
        // engine still running means the audio ran out; the interruption and
        // configuration handlers own the other cases.
        guard schedule == scheduleID, isPlaying, AudioGraph.shared.engine?.isRunning == true else { return }
        isPlaying = false
        lastTime = duration
        onFinish?(true)
    }

    private func halt() {
        isPlaying = false
        scheduleID += 1
        node.stop()
    }

    private func restartIfPlaying() {
        guard isPlaying else { return }
        halt()
        if !play() { onFinish?(false) }
    }

    func pause() {
        guard isPlaying else { return }
        _ = currentTime // capture the position before the node's clock resets
        halt()
        AudioGraph.shared.pause()
    }

    func stop() {
        fade?.cancel()
        fade = nil
        onFinish = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard attached else { return }
        halt()
        attached = false
        AudioGraph.shared.detach(node)
    }

    var currentTime: TimeInterval {
        get {
            if isPlaying, let render = node.lastRenderTime,
               let played = node.playerTime(forNodeTime: render), played.sampleRate > 0 {
                lastTime = min(duration, startTime + max(0, Double(played.sampleTime) / played.sampleRate))
            }
            return lastTime
        }
        set {
            lastTime = newValue.isFinite ? min(duration, max(0, newValue)) : 0
            restartIfPlaying()
        }
    }

    var volume: Float {
        get { node.volume }
        set { setVolume(newValue, fadeDuration: 0) }
    }

    func setVolume(_ volume: Float, fadeDuration: TimeInterval) {
        fade?.cancel()
        fade = nil
        guard fadeDuration > 0 else {
            node.volume = volume
            return
        }
        let initial = node.volume
        let began = Date()
        fade = Task { [weak self] in
            while !Task.isCancelled, let self {
                let progress = min(1, Date().timeIntervalSince(began) / fadeDuration)
                self.node.volume = initial + (volume - initial) * Float(progress)
                if progress >= 1 { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }
}
