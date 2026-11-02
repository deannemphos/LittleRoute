import Testing
@testable import LittleRoute

struct ContextZoneGeometryTests {
    @Test func denseNeighborhoodStaysWithinBoundedMesh() throws {
        _ = try GeometryChecks.denseFixture()
    }

    @Test func defaultTransitionRulesRejectJitterGapsAndPrematureChanges() {
        TransitionChecks.run()
    }

    @Test func weightedPartitionMatchesReferenceAndHasSharedTopology() throws {
        try GeometryChecks.run()
    }
}
