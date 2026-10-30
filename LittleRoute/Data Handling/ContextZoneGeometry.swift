import Foundation

/// A bounded, piecewise-linear approximation of the geographic score field.
/// Map drawing and containment both use this partition, never separate classifiers.
struct ContextZoneGeometry: Sendable {
    struct Point: Hashable, Sendable {
        let x: Double
        let y: Double
    }

    struct Bounds: Equatable, Sendable {
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double

        func contains(_ point: Point) -> Bool {
            point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
        }
    }

    struct Site: Equatable, Sendable {
        let id: String
        let point: Point
        let context: String
        let radius: Double
        let specificity: Double
    }

    struct Region: Identifiable, Sendable {
        let id: String
        let context: String
        let outline: [Point]
        let holes: [[Point]]
    }

    enum GeometryError: Error, LocalizedError {
        case invalidInput, capacityExceeded, invalidTopology

        var errorDescription: String? {
            switch self {
            case .invalidInput: return "The nearby zone data is invalid."
            case .capacityExceeded: return "The nearby zone data exceeds the local map's capacity."
            case .invalidTopology: return "The nearby zone boundaries could not be joined."
            }
        }
    }

    static let fallback = "traveling"
    let bounds: Bounds
    let spacing: Double
    let regions: [Region]
    private let contexts: [String]
    private let columns: Int
    private let rows: Int
    private let samples: [[Double]]

    static func score(contributions: [Double]) -> Double {
        var weight = 1.0
        var result = 0.0
        for value in contributions.sorted(by: >) {
            result += value * weight
            weight *= 0.25
        }
        return result
    }

    static func build(sites: [Site], bounds requested: Bounds, spacing: Double = 10) throws -> Self {
        guard spacing.isFinite, spacing >= 2,
              [requested.minX, requested.minY, requested.maxX, requested.maxY].allSatisfy({ $0.isFinite && abs($0) < 1e9 }),
              requested.maxX > requested.minX, requested.maxY > requested.minY,
              sites.allSatisfy({ $0.point.x.isFinite && $0.point.y.isFinite &&
                  $0.radius.isFinite && $0.radius > 0 && $0.specificity.isFinite &&
                  $0.specificity > 0 && !$0.context.isEmpty && $0.context != fallback }) else {
            throw GeometryError.invalidInput
        }
        let bounds = Bounds(
            minX: floor(requested.minX / spacing) * spacing,
            minY: floor(requested.minY / spacing) * spacing,
            maxX: ceil(requested.maxX / spacing) * spacing,
            maxY: ceil(requested.maxY / spacing) * spacing
        )
        let width = (bounds.maxX - bounds.minX) / spacing
        let height = (bounds.maxY - bounds.minY) / spacing
        guard width <= 200, height <= 200, sites.count <= 256 else {
            throw GeometryError.capacityExceeded
        }
        let columns = Int(width)
        let rows = Int(height)
        // A repeated POI is not additional evidence.
        let unique = Dictionary(sites.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            let a = "\(first.context)|\(first.point.x)|\(first.point.y)|\(first.radius)|\(first.specificity)"
            let b = "\(second.context)|\(second.point.x)|\(second.point.y)|\(second.radius)|\(second.specificity)"
            return a < b ? first : second
        })
        let grouped = Dictionary(grouping: unique.values, by: \.context)
        let contexts = grouped.keys.sorted()
        var samples: [[Double]] = []
        samples.reserveCapacity((columns + 1) * (rows + 1))
        for row in 0...rows {
            try Task.checkCancellation()
            for column in 0...columns {
                let point = Point(x: bounds.minX + Double(column) * spacing,
                                  y: bounds.minY + Double(row) * spacing)
                samples.append(contexts.map { context in
                    score(contributions: (grouped[context] ?? []).compactMap { site in
                        let dx = point.x - site.point.x
                        let dy = point.y - site.point.y
                        guard abs(dx) < site.radius, abs(dy) < site.radius else { return nil }
                        let contribution = max(0, 1 - hypot(dx, dy) / site.radius) * site.specificity
                        return contribution > 0 ? contribution : nil
                    })
                })
            }
        }

        var edges: [String: Set<Edge>] = [:]
        func vertex(_ column: Int, _ row: Int) -> Vertex {
            Vertex(point: Point(x: bounds.minX + Double(column) * spacing,
                                y: bounds.minY + Double(row) * spacing),
                   scores: samples[row * (columns + 1) + column])
        }
        func append(_ polygon: [Vertex], context: String) {
            let points = polygon.map { Key($0.point) }
            guard points.count >= 3, abs(area(points.map(\.point))) > 0.0001 else { return }
            for index in points.indices {
                let edge = Edge(a: points[index], b: points[(index + 1) % points.count])
                guard edge.a != edge.b else { continue }
                if edges[context, default: []].remove(edge.reversed) == nil {
                    edges[context, default: []].insert(edge)
                }
            }
        }
        for row in 0..<rows {
            try Task.checkCancellation()
            for column in 0..<columns {
                let a = vertex(column, row)
                let b = vertex(column + 1, row)
                let c = vertex(column, row + 1)
                let d = vertex(column + 1, row + 1)
                for triangle in [[a, b, c], [b, d, c]] {
                    let winners = triangle.map { winner($0.scores) }
                    if winners[0] == winners[1], winners[1] == winners[2] {
                        append(triangle, context: winners[0].map { contexts[$0] } ?? fallback)
                        continue
                    }
                    for index in contexts.indices where triangle.contains(where: { $0.scores[index] > 0 }) {
                        var polygon = triangle
                        for other in contexts.indices where other != index {
                            polygon = clip(polygon, winner: index, other: other)
                            if polygon.count < 3 { break }
                        }
                        append(polygon, context: contexts[index])
                    }
                }
            }
        }
        var regions: [Region] = []
        for context in edges.keys.sorted() {
            let rings = try rings(from: edges[context] ?? [])
            let outlines = rings.filter { area($0) > 0 }
            let holes = rings.filter { area($0) < 0 }
            var assignedHoles = Array(repeating: [[Point]](), count: outlines.count)
            for hole in holes {
                guard let point = hole.first,
                      let owner = outlines.indices.filter({ contains(point, ring: outlines[$0]) })
                        .min(by: { abs(area(outlines[$0])) < abs(area(outlines[$1])) }) else {
                    throw GeometryError.invalidTopology
                }
                assignedHoles[owner].append(hole)
            }
            for index in outlines.indices {
                let outline = outlines[index]
                let anchor = Key(outline[0])
                let next = Key(outline[1])
                regions.append(Region(id: "\(context)-\(anchor.x)-\(anchor.y)-\(next.x)-\(next.y)",
                                      context: context, outline: outline, holes: assignedHoles[index]))
            }
        }
        return Self(bounds: bounds, spacing: spacing, regions: regions, contexts: contexts,
                    columns: columns, rows: rows, samples: samples)
    }

    func scores(at point: Point) -> [String: Double]? {
        guard point.x.isFinite, point.y.isFinite, bounds.contains(point) else { return nil }
        let x = (point.x - bounds.minX) / spacing
        let y = (point.y - bounds.minY) / spacing
        let column = min(Int(x), columns - 1)
        let row = min(Int(y), rows - 1)
        let dx = x - Double(column)
        let dy = y - Double(row)
        let a = row * (columns + 1) + column
        let b = a + 1
        let c = a + columns + 1
        let d = c + 1
        let values = contexts.indices.map { index in
            if dx + dy <= 1 {
                return samples[a][index] * (1 - dx - dy) + samples[b][index] * dx + samples[c][index] * dy
            }
            return samples[b][index] * (1 - dy) + samples[d][index] * (dx + dy - 1) + samples[c][index] * (1 - dx)
        }
        return Dictionary(uniqueKeysWithValues: zip(contexts, values))
    }

    func context(at point: Point) -> String? {
        guard let scores = scores(at: point) else { return nil }
        return Self.winner(contexts.map { scores[$0] ?? 0 }).map { contexts[$0] } ?? Self.fallback
    }

    func inwardDistance(at point: Point, context: String) -> Double {
        guard self.context(at: point) == context else { return 0 }
        var result = min(point.x - bounds.minX, bounds.maxX - point.x,
                         point.y - bounds.minY, bounds.maxY - point.y)
        for region in regions where region.context == context {
            for ring in [region.outline] + region.holes {
                for index in ring.indices {
                    result = min(result, Self.distance(point, from: ring[index], to: ring[(index + 1) % ring.count]))
                }
            }
        }
        return result
    }

    private struct Vertex {
        let point: Point
        let scores: [Double]
    }

    // Shared intersections are quantized far below location precision, so both
    // sides of a boundary use the same vertex despite floating-point ordering.
    private struct Key: Hashable, Comparable {
        let x: Int64
        let y: Int64
        init(_ point: Point) {
            x = Int64((point.x * 100_000).rounded())
            y = Int64((point.y * 100_000).rounded())
        }
        var point: Point { Point(x: Double(x) / 100_000, y: Double(y) / 100_000) }
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
        }
    }

    private struct Edge: Hashable, Comparable {
        let a: Key
        let b: Key
        var reversed: Self { Self(a: b, b: a) }
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.a == rhs.a ? lhs.b < rhs.b : lhs.a < rhs.a
        }
    }

    private static func winner(_ scores: [Double]) -> Int? {
        var best: Int?
        for index in scores.indices where scores[index] > 0 {
            if best == nil || scores[index] > scores[best!] { best = index }
        }
        return best
    }

    private static func clip(_ vertices: [Vertex], winner: Int, other: Int) -> [Vertex] {
        guard var previous = vertices.last else { return [] }
        if vertices.allSatisfy({ $0.scores[winner] == $0.scores[other] }) {
            return winner < other ? vertices : []
        }
        var previousValue = previous.scores[winner] - previous.scores[other]
        var result: [Vertex] = []
        for current in vertices {
            let value = current.scores[winner] - current.scores[other]
            if (value >= 0) != (previousValue >= 0) {
                let fraction = previousValue / (previousValue - value)
                result.append(Vertex(
                    point: Point(x: previous.point.x + fraction * (current.point.x - previous.point.x),
                                 y: previous.point.y + fraction * (current.point.y - previous.point.y)),
                    scores: zip(previous.scores, current.scores).map { $0 + fraction * ($1 - $0) }
                ))
            }
            if value >= 0 { result.append(current) }
            previous = current
            previousValue = value
        }
        return result
    }

    private static func rings(from edges: Set<Edge>) throws -> [[Point]] {
        var remaining = edges
        var outgoing: [Key: Set<Key>] = [:]
        for edge in edges { outgoing[edge.a, default: []].insert(edge.b) }
        var result: [[Point]] = []
        while let first = remaining.min() {
            var ring = [first.a.point]
            var edge = first
            repeat {
                guard remaining.remove(edge) != nil else { throw GeometryError.invalidTopology }
                outgoing[edge.a]?.remove(edge.b)
                ring.append(edge.b.point)
                if edge.b == first.a { break }
                guard let choices = outgoing[edge.b], !choices.isEmpty else { throw GeometryError.invalidTopology }
                let previous = edge.a.point
                let current = edge.b.point
                let next = choices.sorted().max { lhs, rhs in
                    func turn(_ key: Key) -> Double {
                        let next = key.point
                        let dx = current.x - previous.x
                        let dy = current.y - previous.y
                        return atan2(dx * (next.y - current.y) - dy * (next.x - current.x),
                                     dx * (next.x - current.x) + dy * (next.y - current.y))
                    }
                    return turn(lhs) < turn(rhs)
                }!
                edge = Edge(a: edge.b, b: next)
            } while ring.count <= edges.count + 1
            guard ring.last == ring.first else { throw GeometryError.invalidTopology }
            ring.removeLast()
            let simplified = ring.indices.compactMap { index -> Point? in
                let a = ring[(index + ring.count - 1) % ring.count]
                let b = ring[index]
                let c = ring[(index + 1) % ring.count]
                let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
                return abs(cross) < 1e-8 ? nil : b
            }
            if simplified.count >= 3 { result.append(simplified) }
        }
        return result
    }

    private static func area(_ ring: [Point]) -> Double {
        guard let origin = ring.first else { return 0 }
        return ring.indices.reduce(0) { result, index in
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            return result + ((a.x - origin.x) * (b.y - origin.y) - (b.x - origin.x) * (a.y - origin.y)) / 2
        }
    }

    private static func contains(_ point: Point, ring: [Point]) -> Bool {
        var inside = false
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
        }
        return inside
    }

    private static func distance(_ point: Point, from a: Point, to b: Point) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let fraction = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - a.x - fraction * dx, point.y - a.y - fraction * dy)
    }
}
