import Foundation

struct ContextTransitionState: Sendable {
    let dwell: TimeInterval
    let residence: TimeInterval
    let maximumGap: TimeInterval
    let minimumSamples: Int
    private(set) var candidate: String?
    private(set) var candidateSince: Date?
    private(set) var lastEvidence: Date?
    private(set) var lastConfirmedAt: Date?
    private(set) var samples = 0

    init(dwell: TimeInterval = 30, residence: TimeInterval = 90,
         maximumGap: TimeInterval = 15, minimumSamples: Int = 3) {
        self.dwell = dwell
        self.residence = residence
        self.maximumGap = maximumGap
        self.minimumSamples = minimumSamples
    }

    mutating func observe(_ context: String, confirmed: String, at date: Date, eligible: Bool = true) -> Bool {
        guard eligible, context != confirmed else {
            resetCandidate()
            return false
        }
        if let lastEvidence, date <= lastEvidence { return false }
        if candidate != context || lastEvidence.map({ date.timeIntervalSince($0) > maximumGap }) == true {
            candidate = context
            candidateSince = date
            samples = 0
        }
        lastEvidence = date
        samples += 1
        guard let candidateSince, date.timeIntervalSince(candidateSince) >= dwell,
              samples >= minimumSamples else { return false }
        return remainingResidence(at: date) == 0
    }

    func remainingResidence(at date: Date) -> TimeInterval {
        guard let lastConfirmedAt else { return 0 }
        return max(0, residence - date.timeIntervalSince(lastConfirmedAt))
    }

    mutating func confirm(at date: Date) {
        lastConfirmedAt = date
        resetCandidate()
    }

    mutating func resetCandidate() {
        candidate = nil
        candidateSince = nil
        lastEvidence = nil
        samples = 0
    }
}
