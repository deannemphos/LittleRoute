import Foundation

/// Band levels for the main view's visualizer. Foundation-only so the maths can
/// be checked off-device (see LittleRouteTests/FeatureChecks.swift).
enum Spectrum {
    static let bandCount = 16
    /// How many trailing samples of each tap buffer are analysed.
    static let window = 2_048
    /// Log-spaced band centres, 60 Hz to 12 kHz.
    static let frequencies: [Double] = (0..<bandCount).map {
        60 * pow(200, Double($0) / Double(bandCount - 1))
    }
    /// Calibration: a band at the lower bound draws empty, at the upper bound
    /// full. These are guesses until tuned against real music on a device.
    static let decibelRange = -65.0...(-15.0)

    // ponytail: one Goertzel filter per band, O(bands x samples) per buffer. It
    // samples each band's centre only, so a pure tone between centres does not
    // register; music is broadband enough not to care. Move to a vDSP FFT with
    // summed bins if that shows, or if the band count grows past ~32.
    static func levels<S: Sequence>(samples: S, sampleRate: Double) -> [Float] where S.Element == Float {
        let input = Array(samples)
        guard input.count > 1, sampleRate > 0 else { return [Float](repeating: 0, count: bandCount) }
        // Hann window: without it one loud tone leaks into every band.
        let phase = 2 * Double.pi / Double(input.count - 1)
        let windowed: [Double] = input.indices.map { Double(input[$0]) * (0.5 - 0.5 * cos(phase * Double($0))) }
        return frequencies.map { frequency in
            let coefficient = 2 * cos(2 * Double.pi * frequency / sampleRate)
            var previous = 0.0, beforePrevious = 0.0
            for sample in windowed {
                let current = sample + coefficient * previous - beforePrevious
                beforePrevious = previous
                previous = current
            }
            let power = previous * previous + beforePrevious * beforePrevious
                - coefficient * previous * beforePrevious
            // 4|X|/N is the amplitude of a sine on this band (the window halves it).
            let amplitude = 4 * max(0, power).squareRoot() / Double(input.count)
            let decibels = 20 * log10(max(amplitude, 1e-9))
            let level = (decibels - decibelRange.lowerBound) / (decibelRange.upperBound - decibelRange.lowerBound)
            return level.isFinite ? Float(min(1, max(0, level))) : 0
        }
    }
}
