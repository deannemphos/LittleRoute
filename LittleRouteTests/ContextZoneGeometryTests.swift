import Testing
@testable import LittleRoute

struct ContextZoneGeometryTests {
    @Test func defaultTransitionRulesRejectJitterGapsAndPrematureChanges() {
        TransitionChecks.run()
    }

    @Test func weightedPartitionHasSharedBoundariesAndCorrectHoles() throws {
        try GeometryChecks.run()
    }
}
