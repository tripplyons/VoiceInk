import Foundation

/// Levels speech without letting an isolated peak set the gain for the whole recording.
enum SpeechAudioNormalizer {
    static let targetRMS: Float = 0.1

    static func normalize(_ samples: inout [Float], sampleRate: Double) {
        let levels = samples.withUnsafeBufferPointer { buffer in
            frameRMS(buffer, sampleRate: sampleRate)
        }
        let gain = normalizationGain(for: levels)
        var limiter = SpeechAudioLimiter(sampleRate: sampleRate)

        samples.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            limiter.process(baseAddress, count: buffer.count, gain: gain)
        }
    }

    static func frameRMS(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let frameSize = max(1, Int(sampleRate * 0.02))
        var levels: [Float] = []
        levels.reserveCapacity((samples.count + frameSize - 1) / frameSize)

        for start in stride(from: 0, to: samples.count, by: frameSize) {
            let end = min(start + frameSize, samples.count)
            var squareSum: Float = 0
            for index in start..<end {
                squareSum += samples[index] * samples[index]
            }
            levels.append(sqrt(squareSum / Float(end - start)))
        }
        return levels
    }

    static func normalizationGain(for frameLevels: [Float]) -> Float {
        let sortedLevels = frameLevels.sorted()
        guard sortedLevels.count >= 3 else { return 1 }

        let noiseFloor = percentile(0.15, in: sortedLevels)
        let speechGate = max(0.008, noiseFloor * 1.8)
        let speechLevels = sortedLevels.filter { $0 >= speechGate }
        let minimumSpeechFrames = max(3, Int(Double(frameLevels.count) * 0.03))
        guard speechLevels.count >= minimumSpeechFrames else { return 1 }

        let speechLevel = percentile(0.55, in: speechLevels)
        guard speechLevel > 0 else { return 1 }
        return min(max(targetRMS / speechLevel, 0.5), 4)
    }

    private static func percentile(_ percentile: Double, in sortedValues: [Float]) -> Float {
        guard !sortedValues.isEmpty else { return 0 }
        let index = Int((Double(sortedValues.count - 1) * percentile).rounded())
        return sortedValues[index]
    }
}

/// Streaming speech leveling driven by recent audio and smooth EMA state.
struct StreamingSpeechLeveler {
    private let sampleRate: Double
    private var fastLevelEMA = SpeechAudioNormalizer.targetRMS
    private var slowLevelEMA = SpeechAudioNormalizer.targetRMS
    private var appliedGain: Float = 1
    private var limiter: SpeechTransientLimiter

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        limiter = SpeechTransientLimiter(sampleRate: sampleRate)
    }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }

        var squareSum: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            squareSum += sample * sample
            peak = max(peak, abs(sample))
        }

        let rms = sqrt(squareSum / Float(count))
        let crestFactor = peak / max(rms, 0.000_001)
        let levelWeight = smoothstep(rms, lowerBound: 0.003, upperBound: 0.012)
        let transientWeight = 1 - smoothstep(crestFactor, lowerBound: 6, upperBound: 10)
        let speechWeight = levelWeight * transientWeight
        let neutralLevel = SpeechAudioNormalizer.targetRMS
        let observedLevel = neutralLevel + speechWeight * (rms - neutralLevel)
        let duration = Double(count) / sampleRate

        // The fast EMA follows quieter speech promptly. The slow EMA prevents a loud
        // interval from taking over; silence smoothly pulls both back toward unity gain.
        fastLevelEMA = ema(
            fastLevelEMA,
            toward: observedLevel,
            duration: duration,
            timeConstant: 0.25
        )
        slowLevelEMA = ema(
            slowLevelEMA,
            toward: observedLevel,
            duration: duration,
            timeConstant: 0.75 + 0.75 * Double(speechWeight)
        )

        let estimatedSpeechRMS = min(fastLevelEMA, slowLevelEMA)
        let desiredGain = min(max(neutralLevel / estimatedSpeechRMS, 0.5), 4)
        let risingCoefficient = smoothingCoefficient(milliseconds: 150)
        let fallingCoefficient = smoothingCoefficient(milliseconds: 20)

        for index in 0..<count {
            let coefficient = desiredGain > appliedGain ? risingCoefficient : fallingCoefficient
            appliedGain = coefficient * appliedGain + (1 - coefficient) * desiredGain
            samples[index] = limiter.process(samples[index] * appliedGain)
        }
    }

    mutating func process(_ samples: inout [Float]) {
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            process(baseAddress, count: buffer.count)
        }
    }

    private func ema(
        _ current: Float,
        toward target: Float,
        duration: Double,
        timeConstant: Double
    ) -> Float {
        let blend = Float(1 - exp(-duration / timeConstant))
        return current + blend * (target - current)
    }

    private func smoothstep(
        _ value: Float,
        lowerBound: Float,
        upperBound: Float
    ) -> Float {
        let position = min(max((value - lowerBound) / (upperBound - lowerBound), 0), 1)
        return position * position * (3 - 2 * position)
    }

    private func smoothingCoefficient(milliseconds: Double) -> Float {
        Float(exp(-1 / (sampleRate * milliseconds / 1_000)))
    }
}

struct SpeechAudioLimiter {
    private var limiter: SpeechTransientLimiter

    init(sampleRate: Double) {
        limiter = SpeechTransientLimiter(sampleRate: sampleRate)
    }

    mutating func process(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int,
        gain: Float = 1
    ) {
        for index in 0..<count {
            samples[index] = limiter.process(samples[index] * gain)
        }
    }
}

private struct SpeechTransientLimiter {
    private let releaseCoefficient: Float
    private let recoveryCoefficient: Float
    private var envelope: Float = 0
    private var gain: Float = 1

    init(sampleRate: Double) {
        releaseCoefficient = Float(exp(-1 / (sampleRate * 0.04)))
        recoveryCoefficient = Float(exp(-1 / (sampleRate * 0.035)))
    }

    mutating func process(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        envelope = max(magnitude, envelope * releaseCoefficient)

        let threshold: Float = 0.32
        let desiredGain: Float
        if envelope > threshold {
            let compressedLevel = threshold * pow(envelope / threshold, 0.25)
            desiredGain = compressedLevel / envelope
        } else {
            desiredGain = 1
        }

        if desiredGain < gain {
            gain = desiredGain
        } else {
            gain = recoveryCoefficient * gain + (1 - recoveryCoefficient) * desiredGain
        }

        return min(max(sample * gain, -0.95), 0.95)
    }
}
