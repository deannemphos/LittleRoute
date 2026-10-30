import Foundation
#if canImport(LittleRoute)
@testable import LittleRoute
#endif

enum TransitionChecks {
    static func run() {
        let origin = Date(timeIntervalSince1970: 0)
        var state = ContextTransitionState()
        for seconds in stride(from: 0, to: 30, by: 5) {
            precondition(!state.observe("park", confirmed: "all", at: origin.addingTimeInterval(Double(seconds))))
        }
        precondition(state.observe("park", confirmed: "all", at: origin.addingTimeInterval(30)))
        state.confirm(at: origin.addingTimeInterval(30))
        for seconds in stride(from: 35, to: 120, by: 5) {
            precondition(!state.observe("gym", confirmed: "park", at: origin.addingTimeInterval(Double(seconds))))
        }
        precondition(state.observe("gym", confirmed: "park", at: origin.addingTimeInterval(120)))
        state.confirm(at: origin.addingTimeInterval(120))
        for seconds in stride(from: 125, through: 725, by: 5) {
            precondition(!state.observe("park", confirmed: "gym", at: origin.addingTimeInterval(Double(seconds)), eligible: false))
        }
        precondition(state.candidate == nil)
        var interrupted = ContextTransitionState()
        precondition(!interrupted.observe("park", confirmed: "all", at: origin))
        precondition(!interrupted.observe("park", confirmed: "all", at: origin.addingTimeInterval(10)))
        precondition(!interrupted.observe("park", confirmed: "all", at: origin.addingTimeInterval(40)))
        precondition(interrupted.candidateSince == origin.addingTimeInterval(40))
        let samples = interrupted.samples
        precondition(!interrupted.observe("park", confirmed: "all", at: origin.addingTimeInterval(40)))
        precondition(interrupted.samples == samples)
        precondition(!interrupted.observe("gym", confirmed: "all", at: origin.addingTimeInterval(45)))
        precondition(interrupted.candidateSince == origin.addingTimeInterval(45))
        precondition(!interrupted.observe("all", confirmed: "all", at: origin.addingTimeInterval(50)))
        precondition(interrupted.candidate == nil)
    }
}
