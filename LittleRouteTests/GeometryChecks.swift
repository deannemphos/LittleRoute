import Foundation
#if canImport(LittleRoute)
@testable import LittleRoute
#endif

enum GeometryChecks {
    static func run() throws {
        typealias Geometry = ContextZoneGeometry
        let bounds = Geometry.Bounds(minX: -250, minY: -250, maxX: 250, maxY: 250)
        func site(_ id: String, _ context: String, x: Double, y: Double = 0,
                  radius: Double = 100, specificity: Double = 1) -> Geometry.Site {
            Geometry.Site(id: id, point: .init(x: x, y: y), context: context,
                          radius: radius, specificity: specificity)
        }
        let empty = try Geometry.build(sites: [], bounds: bounds)
        precondition(empty.context(at: .init(x: 0, y: 0)) == Geometry.fallback)
        precondition(empty.regions.count == 1)
        precondition(empty.regions[0].outline.count == 4)
        precondition(empty.context(at: .init(x: 251, y: 0)) == nil)

        let sites = [site("park", "park", x: 0, radius: 200),
                     site("gym", "gym", x: 0, radius: 45, specificity: 2),
                     site("store", "store", x: 150, y: 50, radius: 70, specificity: 1.5)]
        let mesh = try Geometry.build(sites: sites, bounds: bounds)
        precondition(mesh.context(at: .init(x: 0, y: 0)) == "gym")
        precondition(mesh.context(at: .init(x: -100, y: 0)) == "park")
        precondition(mesh.context(at: .init(x: -240, y: -240)) == Geometry.fallback)
        precondition(mesh.regions.contains { $0.context == "park" && !$0.holes.isEmpty })
        precondition(mesh.inwardDistance(at: .init(x: 0, y: 0), context: "gym") > 20)
        precondition(mesh.inwardDistance(at: .init(x: 0, y: 0), context: "park") == 0)
        precondition(Set(mesh.regions.map(\.id)).count == mesh.regions.count)
        let reordered = try Geometry.build(sites: sites.reversed(), bounds: bounds)
        precondition(mesh.regions.map(\.id) == reordered.regions.map(\.id))
        let duplicate = try Geometry.build(sites: sites + [sites[0]], bounds: bounds)
        precondition(mesh.regions.map(\.id) == duplicate.regions.map(\.id))

        func contains(_ point: Geometry.Point, ring: [Geometry.Point]) -> Bool {
            var result = false
            for index in ring.indices {
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                    result.toggle()
                }
            }
            return result
        }
        // Offset the lattice so this checks interiors, not floating-point ties.
        for x in stride(from: -249.37, to: 250, by: 4) {
            for y in stride(from: -249.19, to: 250, by: 4) {
                let point = Geometry.Point(x: x, y: y)
                let owners = mesh.regions.filter {
                    contains(point, ring: $0.outline) && !$0.holes.contains { contains(point, ring: $0) }
                }
                precondition(owners.count == 1, "Overlapping or missing geographic ownership at \(point)")
                precondition(owners.first?.context == mesh.context(at: point), "Map and lookup disagree")
            }
        }
        let weighted = try Geometry.build(sites: [
            site("wide", "park", x: 150, radius: 600, specificity: 1.2),
            site("near", "restaurant", x: 50, radius: 70, specificity: 0.7)
        ], bounds: bounds)
        precondition(weighted.context(at: .init(x: 0, y: 0)) == "park")
        let tied = try Geometry.build(sites: [
            site("one", "gym", x: 0), site("two", "park", x: 0)
        ], bounds: bounds)
        precondition(tied.context(at: .init(x: 0, y: 0)) == "gym")
        precondition(!tied.regions.contains { $0.context == "park" })
        precondition(abs(Geometry.score(contributions: [0.5, 1, 0.25]) - 1.140625) < 1e-10)
        do {
            _ = try Geometry.build(sites: [], bounds: .init(minX: 0, minY: 0, maxX: 100_000, maxY: 100_000))
            preconditionFailure("Unbounded geometry was accepted")
        } catch Geometry.GeometryError.capacityExceeded {}
    }
}
