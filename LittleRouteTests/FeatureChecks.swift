import Foundation
#if canImport(LittleRoute)
@testable import LittleRoute
#endif

/// Foundation-only checks, runnable without Apple frameworks like GeometryChecks.
enum FeatureChecks {
    static func run() throws {
        // A tone lands in its own visualizer band, and silence draws nothing.
        let sampleRate = 44_100.0
        for band in [0, 5, 10, Spectrum.bandCount - 1] {
            let frequency = Spectrum.frequencies[band]
            let step: Double = 2 * Double.pi * frequency / sampleRate
            let tone: [Float] = (0..<Spectrum.window).map { Float(0.5 * sin(step * Double($0))) }
            let levels = Spectrum.levels(samples: tone, sampleRate: sampleRate)
            precondition(levels.count == Spectrum.bandCount)
            precondition(levels.allSatisfy { (0...1).contains($0) })
            precondition(levels.firstIndex(of: levels.max()!) == band, "band \(band): \(levels)")
        }
        let silence = [Float](repeating: 0, count: Spectrum.window)
        precondition(Spectrum.levels(samples: silence, sampleRate: sampleRate).allSatisfy { $0 == 0 })
        precondition(Spectrum.levels(samples: [Float](), sampleRate: sampleRate).allSatisfy { $0 == 0 })
        precondition(Spectrum.levels(samples: [Float.nan, .infinity], sampleRate: 0).allSatisfy { $0 == 0 })
        precondition(Spectrum.levels(samples: [Float.nan, .infinity], sampleRate: sampleRate).allSatisfy { $0.isFinite })

        // Custom places reject what the zone geometry cannot draw, and survive storage.
        precondition(CustomPlace(name: "  ", latitude: 0, longitude: 0, contextKey: "home") == nil)
        precondition(CustomPlace(name: "Pole", latitude: 89, longitude: 0, contextKey: "home") == nil)
        precondition(CustomPlace(name: "Nowhere", latitude: .nan, longitude: 0, contextKey: "home") == nil)
        precondition(CustomPlace(name: "Untagged", latitude: 0, longitude: 0, contextKey: "") == nil)
        let home = CustomPlace(name: "  Home \n", latitude: 39.29, longitude: -76.61, contextKey: "home", radius: 5)!
        precondition(home.name == "Home")
        precondition(home.radius == CustomPlace.radiusRange.lowerBound)
        precondition(CustomPlace(name: "Wide", latitude: 0, longitude: 0, contextKey: "work", radius: .infinity)!.radius
                     == CustomPlace.defaultRadius)
        let stored = try JSONDecoder().decode([CustomPlace].self, from: JSONEncoder().encode([home]))
        precondition(stored == [home])
        let tampered = Data(#"[{"id":"\#(UUID().uuidString)","name":"X","latitude":0,"longitude":0,"contextKey":"home","radius":-1}]"#.utf8)
        let decoded = try JSONDecoder().decode([CustomPlace].self, from: tampered)
        precondition(decoded.count == 1 && !decoded[0].isValid)
    }
}
