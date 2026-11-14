import Foundation
#if canImport(LittleRoute)
@testable import LittleRoute
#endif

enum GeometryChecks {
    private typealias Geometry = ContextZoneGeometry
    private typealias Point = Geometry.Point

    private static let denseBounds = Geometry.Bounds(minX: -600, minY: -600, maxX: 600, maxY: 600)

    private static var denseSites: [Geometry.Site] {
        let contexts = ["beach", "gym", "restaurant", "store", "park", "city"]
        let radii = [600.0, 120, 70, 90, 600, 400]
        let specificity = [1.3, 1.05, 0.7, 0.8, 1.2, 0.9]
        return (0..<100).map { index in
            let point = Point(x: Double(index % 10) * 100 - 450,
                              y: Double(index / 10) * 100 - 450)
            let category = index % contexts.count
            return Geometry.Site(id: "\(index)", point: point,
                context: contexts[category], radius: radii[category], specificity: specificity[category])
        }
    }

    static func denseFixture() throws -> TimeInterval {
        let sites = denseSites
        let start = ContinuousClock.now
        let geometry = try Geometry.build(sites: sites, bounds: denseBounds)
        let duration = start.duration(to: .now).components
        checkTopology(geometry)
        checkOwnership(geometry, step: 10)
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private static func contains(_ point: Point, ring: [Point]) -> Bool {
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

    private static func checkOwnership(_ geometry: Geometry, step: Double = 4) {
        // Avoid exact boundary ties; polygon interiors must have exactly one owner.
        for x in stride(from: geometry.bounds.minX + 0.63, to: geometry.bounds.maxX, by: step) {
            for y in stride(from: geometry.bounds.minY + 0.81, to: geometry.bounds.maxY, by: step) {
                checkOwnership(at: Point(x: x, y: y), geometry: geometry)
            }
        }
    }

    private static func checkOwnership(at point: Point, geometry: Geometry) {
        let owners = geometry.regions.filter {
            contains(point, ring: $0.outline) && !$0.holes.contains { contains(point, ring: $0) }
        }
        precondition(owners.count == 1, "Overlapping or missing geographic ownership at \(point)")
        precondition(owners.first?.context == geometry.context(at: point), "Map and lookup disagree at \(point)")
        let scores = geometry.scores(at: point)!
        precondition((geometry.context(at: point) == Geometry.fallback) == scores.values.allSatisfy { $0 == 0 },
                     "A zero-score context won at \(point)")
    }

    private static func signedArea(_ ring: [Point]) -> Double {
        let origin = ring[0]
        return ring.indices.reduce(0) { total, index in
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            return total + ((a.x - origin.x) * (b.y - origin.y) - (b.x - origin.x) * (a.y - origin.y)) / 2
        }
    }

    private static func checkTopology(_ geometry: Geometry) {
        precondition(!geometry.regions.isEmpty)
        precondition(Set(geometry.regions.map(\.id)).count == geometry.regions.count)
        var edges: [(a: Point, b: Point, context: String)] = []
        var area = 0.0
        for region in geometry.regions {
            precondition(signedArea(region.outline) > 0)
            for hole in region.holes {
                precondition(signedArea(hole) < 0)
                precondition(contains(hole[0], ring: region.outline))
            }
            for ring in [region.outline] + region.holes {
                precondition(ring.count >= 3 && Set(ring).count == ring.count, "A ring is not simple")
                area += signedArea(ring)
                for index in ring.indices {
                    edges.append((ring[index], ring[(index + 1) % ring.count], region.context))
                }
            }
        }
        let bounds = geometry.bounds
        let expectedArea = (bounds.maxX - bounds.minX) * (bounds.maxY - bounds.minY)
        precondition(abs(area - expectedArea) < expectedArea * 1e-8, "Partition does not cover its bounds")
        for edge in edges {
            if (edge.a.x == bounds.minX && edge.b.x == bounds.minX) ||
                (edge.a.x == bounds.maxX && edge.b.x == bounds.maxX) ||
                (edge.a.y == bounds.minY && edge.b.y == bounds.minY) ||
                (edge.a.y == bounds.maxY && edge.b.y == bounds.maxY) { continue }
            let dx = edge.b.x - edge.a.x
            let dy = edge.b.y - edge.a.y
            let length = hypot(dx, dy)
            let tolerance = 0.00003 / length
            // Simplifying collinear vertices can split one side of a shared edge.
            let spans: [(Double, Double)] = edges.compactMap { other in
                guard other.context != edge.context,
                      dx * (other.b.x - other.a.x) + dy * (other.b.y - other.a.y) < 0,
                      abs(dx * (other.a.y - edge.a.y) - dy * (other.a.x - edge.a.x)) / length < 0.00003,
                      abs(dx * (other.b.y - edge.a.y) - dy * (other.b.x - edge.a.x)) / length < 0.00003 else { return nil }
                let a = ((other.a.x - edge.a.x) * dx + (other.a.y - edge.a.y) * dy) / (length * length)
                let b = ((other.b.x - edge.a.x) * dx + (other.b.y - edge.a.y) * dy) / (length * length)
                return (max(0, b), min(1, a))
            }.filter { $0.1 >= $0.0 }.sorted { $0.0 < $1.0 }
            var covered = 0.0
            for span in spans {
                precondition(span.0 <= covered + tolerance, "A shared boundary has a gap")
                covered = max(covered, span.1)
            }
            precondition(covered >= 1 - tolerance, "A boundary has no reversed neighbor: \(edge)")
        }
    }

    private static func directScores(_ point: Point, sites: [Geometry.Site]) -> [String: Double] {
        let grouped = Dictionary(grouping: sites, by: \.context)
        return grouped.mapValues { sites in
            let contributions = sites.map { site in
                max(0, 1 - hypot(point.x - site.point.x, point.y - site.point.y) / site.radius) * site.specificity
            }.sorted(by: >)
            return contributions.enumerated().reduce(0) { $0 + $1.element * pow(0.25, Double($1.offset)) }
        }
    }

    private static func referenceGrid(_ geometry: Geometry, sites: [Geometry.Site]) -> (points: Int, ambiguous: Int) {
        let xs = Array(stride(from: geometry.bounds.minX + 1, to: geometry.bounds.maxX, by: 2))
        let ys = Array(stride(from: geometry.bounds.minY + 1, to: geometry.bounds.maxY, by: 2))
        let reference = ys.flatMap { y in xs.map { x in
            let scores = directScores(Point(x: x, y: y), sites: sites)
            var winner = Geometry.fallback
            var best = 0.0
            for context in scores.keys.sorted() where scores[context]! > best {
                winner = context
                best = scores[context]!
            }
            return winner
        } }
        var ambiguous = 0
        for column in xs.indices {
            for row in ys.indices {
                let point = Point(x: xs[column], y: ys[row])
                let expected = reference[row * xs.count + column]
                let actual = geometry.context(at: point)!
                if expected != actual {
                    // Use the independent reference boundary: a sub-mesh island
                    // can disappear, leaving no nearby polygon boundary to measure.
                    let nearBoundary = (-10...10).contains { dx in
                        (-10...10).contains { dy in
                            let x = column + dx
                            let y = row + dy
                            return dx * dx + dy * dy <= 100 && xs.indices.contains(x) && ys.indices.contains(y) &&
                                reference[y * xs.count + x] != expected
                        }
                    }
                    precondition(nearBoundary,
                                 "2 m reference disagrees outside the 20 m boundary band at \(point): \(expected) != \(actual)")
                    ambiguous += 1
                }
            }
        }
        // Mesh vertices must retain the exact weighted scorer, not just its winner.
        for x in stride(from: geometry.bounds.minX, through: geometry.bounds.maxX, by: 10) {
            for y in stride(from: geometry.bounds.minY, through: geometry.bounds.maxY, by: 10) {
                let point = Point(x: x, y: y)
                let expected = directScores(point, sites: sites)
                let actual = geometry.scores(at: point)!
                precondition(expected.allSatisfy { abs(actual[$0.key]! - $0.value) < 1e-12 })
            }
        }
        return (reference.count, ambiguous)
    }

    private static func randomizedChecks() throws {
        let bounds = Geometry.Bounds(minX: -250, minY: -250, maxX: 250, maxY: 250)
        let contexts = ["beach", "city", "gym", "park", "restaurant", "store"]
        var state: UInt64 = 0xC0FFEE
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9_007_199_254_740_992
        }
        var totals = (points: 0, ambiguous: 0)
        for fixture in 0..<8 {
            let sites = (0..<40).map { index in
                Geometry.Site(id: "\(index)", point: .init(x: random() * 460 - 230, y: random() * 460 - 230),
                              context: contexts[index % contexts.count], radius: 15 + random() * 220,
                              specificity: 0.5 + random() * 1.5)
            }
            let geometry = try Geometry.build(sites: sites, bounds: bounds)
            checkTopology(geometry)
            checkOwnership(geometry)
            for site in sites { checkOwnership(at: site.point, geometry: geometry) }
            if fixture == 0 {
                // This face is under 0.0001 m²; dropping it left a real map gap.
                checkOwnership(at: .init(x: -149.995, y: 139.9975), geometry: geometry)
            }
            let reordered = try Geometry.build(sites: sites.reversed(), bounds: bounds)
            precondition(geometry.regions.map(\.id) == reordered.regions.map(\.id), "Unstable random fixture \(fixture)")
            let result = referenceGrid(geometry, sites: sites)
            totals.points += result.points
            totals.ambiguous += result.ambiguous
        }
        let dense = try Geometry.build(sites: denseSites, bounds: denseBounds)
        let result = referenceGrid(dense, sites: denseSites)
        totals.points += result.points
        totals.ambiguous += result.ambiguous
        print("2 m weighted reference: \(totals.points) points; \(totals.ambiguous) differences within 20 m; none outside.")
    }

    static func run() throws {
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

        checkTopology(empty)
        checkTopology(mesh)
        checkOwnership(mesh)
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
        checkTopology(tied)
        checkOwnership(tied)
        let junction = try Geometry.build(sites: [
            site("north", "beach", x: 0, y: 100, radius: 200),
            site("west", "gym", x: -100, radius: 200),
            site("east", "park", x: 100, radius: 200)
        ], bounds: bounds)
        precondition(junction.context(at: .init(x: 0, y: 0)) == "beach")
        precondition(junction.context(at: .init(x: -0.1, y: 0)) == "gym")
        precondition(junction.context(at: .init(x: 0.1, y: 0)) == "park")
        precondition(junction.context(at: .init(x: 0, y: 0.1)) == "beach")
        checkTopology(junction)
        checkOwnership(junction)
        let islands = try Geometry.build(sites: [
            site("wide", "park", x: 0, radius: 240),
            site("west", "gym", x: -70, radius: 30, specificity: 3),
            site("east", "gym", x: 70, radius: 30, specificity: 3),
            site("center", "store", x: 0, radius: 10, specificity: 10)
        ], bounds: bounds)
        precondition(islands.regions.filter { $0.context == "gym" }.count == 2)
        precondition(islands.regions.contains { $0.context == "park" && $0.holes.count == 3 })
        checkTopology(islands)
        checkOwnership(islands)
        let inactive = try Geometry.build(sites: [
            site("absent", "beach", x: 2_000),
            site("active", "park", x: 0, radius: 70)
        ], bounds: bounds)
        precondition(!inactive.regions.contains { $0.context == "beach" })
        precondition(inactive.context(at: .init(x: 200, y: 200)) == Geometry.fallback)
        checkTopology(inactive)
        checkOwnership(inactive)
        let tinyIsland = try Geometry.build(sites: [
            site("wide", "park", x: 0, radius: 100),
            site("narrow", "gym", x: 0, radius: 10, specificity: 1.0000045)
        ], bounds: .init(minX: -10, minY: -10, maxX: 10, maxY: 10))
        precondition(tinyIsland.context(at: .init(x: 0, y: 0)) == "gym")
        checkTopology(tinyIsland)
        checkOwnership(at: .init(x: 0, y: 0), geometry: tinyIsland)
        precondition(abs(Geometry.score(contributions: [0.5, 1, 0.25]) - 1.140625) < 1e-10)
        do {
            _ = try Geometry.build(sites: [], bounds: .init(minX: 0, minY: 0, maxX: 100_000, maxY: 100_000))
            preconditionFailure("Unbounded geometry was accepted")
        } catch Geometry.GeometryError.capacityExceeded {}
        try randomizedChecks()
    }
}
