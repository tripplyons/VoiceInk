import Foundation

/// Stateful, windowed-sinc conversion. Retains fractional position across chunks
/// and waits for the right half of the kernel instead of adding delay to output.
final class StreamingAudioResampler {
    private static let radius = 16
    private static let phases = 256
    private let step: Double
    private let coefficients: [[Float]]
    private var history = [Float](repeating: 0, count: 128)
    private var received = 0
    private var emitted = 0
    private var finished = false

    init(inputRate: Double, outputRate: Double) {
        precondition(inputRate.isFinite && outputRate.isFinite && inputRate > 0 && outputRate > 0)
        step = inputRate / outputRate
        let cutoff = min(1, outputRate / inputRate) * 0.94
        coefficients = (0..<Self.phases).map { phase in
            let fraction = Double(phase) / Double(Self.phases)
            var taps = (-Self.radius...Self.radius).map { offset -> Float in
                let distance = Double(offset) - fraction
                let x = Double.pi * cutoff * distance
                let sinc = abs(x) < 1e-12 ? 1 : sin(x) / x
                let window = abs(distance) <= Double(Self.radius)
                    ? 0.5 + 0.5 * cos(Double.pi * distance / Double(Self.radius)) : 0
                return Float(cutoff * sinc * window)
            }
            let sum = taps.reduce(0, +)
            for index in taps.indices { taps[index] /= sum }
            return taps
        }
    }

    func process(_ samples: UnsafePointer<Float>, count: Int, emit: (Float) -> Void) {
        guard !finished, count > 0 else { return }
        for index in 0..<count { process(samples[index], emit: emit) }
    }

    func process(_ sample: Float, emit: (Float) -> Void) {
        guard !finished else { return }
        history[received % history.count] = sample.isFinite ? sample : 0
        received += 1
        while Double(emitted) * step + Double(Self.radius) < Double(received) {
            emit(interpolatedSample())
            emitted += 1
        }
    }

    func finish(emit: (Float) -> Void) {
        guard !finished else { return }
        finished = true
        // Round up here; the owning pipeline trims to the original frame count.
        let target = Int(ceil(Double(received) / step))
        while emitted < target {
            emit(interpolatedSample())
            emitted += 1
        }
    }

    private func interpolatedSample() -> Float {
        let position = Double(emitted) * step
        let center = Int(position)
        let phase = min(Self.phases - 1, Int((position - Double(center)) * Double(Self.phases)))
        var result: Float = 0
        for offset in -Self.radius...Self.radius {
            let index = center + offset
            if index >= 0, index < received, index >= received - history.count {
                result += history[index % history.count] * coefficients[phase][offset + Self.radius]
            }
        }
        return result
    }
}
