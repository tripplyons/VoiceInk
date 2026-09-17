import Foundation

/// Levels audio to a consistent RMS from its recent measured amplitude.
enum SpeechAudioNormalizer {
    static let targetRMS: Float = 0.1

    static func normalize(_ samples: inout [Float], sampleRate: Double, strength: Float = 1) {
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate, strength: strength)
        leveler.process(&samples)
    }

    static func gain(forMeasuredRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 1 }
        return targetRMS / rms
    }
}

/// Streaming audio leveling driven by fixed-size analysis frames and a short
/// recent-level window. Every nonzero amplitude contributes to the gain estimate;
/// there is no level gate or minimum/maximum gain policy.
struct StreamingSpeechLeveler {
    private let strength: Float
    private let sampleRate: Double
    private let analysisFrameSize: Int
    private var analysisSampleCount = 0
    private var analysisSquareSum: Double = 0

    private var levelEstimator = RecentLevelEstimator()
    private var desiredGain: Float = 1
    private var appliedGain: Float = 1
    private var rumbleFilters: [SpeechRumbleFilter]
    private var limiters: [SpeechTransientLimiter]

    private static let gainReductionTimeConstant: Double = 0.008
    private static let gainRecoveryTimeConstant: Double = 0.05
    private let gainReductionCoefficient: Float
    private let gainRecoveryCoefficient: Float

    init(sampleRate: Double, strength: Float = 1) {
        self.strength = NormalizationSettings.validatedStrength(strength)
        let safeSampleRate = max(sampleRate, 1)
        self.sampleRate = safeSampleRate
        analysisFrameSize = max(1, Int(safeSampleRate * 0.02))
        gainReductionCoefficient = Float(
            exp(-1 / (safeSampleRate * Self.gainReductionTimeConstant))
        )
        gainRecoveryCoefficient = Float(
            exp(-1 / (safeSampleRate * Self.gainRecoveryTimeConstant))
        )
        rumbleFilters = [SpeechRumbleFilter(sampleRate: safeSampleRate)]
        limiters = [SpeechTransientLimiter(sampleRate: safeSampleRate)]
    }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }

        for index in 0..<count {
            let sample = rumbleFilters[0].process(samples[index])
            trackAnalysis(sampleSquare: Double(sample) * Double(sample))
            updateAppliedGain()
            samples[index] = limiters[0].process(sample * appliedGain)
        }
    }

    /// Uses one speech estimate for all channels so adaptive gain preserves balance;
    /// transient limiting remains independent per channel.
    mutating func process(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) {
        guard channelCount > 0, frameCount > 0 else { return }
        ensureLimiterCount(channelCount)

        for frame in 0..<frameCount {
            var squareSum: Double = 0
            for channel in 0..<channelCount {
                let sample = rumbleFilters[channel].process(channels[channel][frame])
                channels[channel][frame] = sample
                squareSum += Double(sample) * Double(sample)
            }

            trackAnalysis(sampleSquare: squareSum / Double(channelCount))
            updateAppliedGain()

            for channel in 0..<channelCount {
                let sample = channels[channel][frame]
                channels[channel][frame] = limiters[channel].process(sample * appliedGain)
            }
        }
    }

    mutating func process(_ samples: inout [Float]) {
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            process(baseAddress, count: buffer.count)
        }
    }

    private mutating func trackAnalysis(sampleSquare: Double) {
        analysisSampleCount += 1
        analysisSquareSum += sampleSquare

        if analysisSampleCount == analysisFrameSize {
            updateEffectiveLevel()
            analysisSampleCount = 0
            analysisSquareSum = 0
        }
    }

    private mutating func updateAppliedGain() {
        let coefficient = desiredGain < appliedGain
            ? gainReductionCoefficient
            : gainRecoveryCoefficient
        appliedGain = coefficient * appliedGain + (1 - coefficient) * desiredGain
    }

    private mutating func ensureLimiterCount(_ count: Int) {
        guard limiters.count != count else { return }
        rumbleFilters = (0..<count).map { _ in
            SpeechRumbleFilter(sampleRate: sampleRate)
        }
        limiters = (0..<count).map { _ in
            SpeechTransientLimiter(sampleRate: sampleRate)
        }
    }

    private mutating func updateEffectiveLevel() {
        guard analysisSampleCount > 0 else { return }

        let rms = Float(sqrt(analysisSquareSum / Double(analysisSampleCount)))
        guard rms.isFinite, rms > 0 else {
            resetToNeutral()
            return
        }

        let effectiveRMS = levelEstimator.update(with: rms)
        let gain = SpeechAudioNormalizer.gain(forMeasuredRMS: effectiveRMS)
        guard gain.isFinite else {
            resetToNeutral()
            return
        }
        // Scale the correction in decibels, not the target loudness.
        desiredGain = strength == 0 ? 1 : pow(gain, strength)
    }

    private mutating func resetToNeutral() {
        levelEstimator.reset()
        desiredGain = 1
    }
}

/// Removes handling and room rumble before it can be amplified as speech.
private struct SpeechRumbleFilter {
    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    init(sampleRate: Double) {
        let frequency = min(70, sampleRate * 0.49)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * sqrt(0.5))
        let a0 = 1 + alpha

        b0 = Float(((1 + cosine) / 2) / a0)
        b1 = Float((-(1 + cosine)) / a0)
        b2 = Float(((1 + cosine) / 2) / a0)
        a1 = Float((-2 * cosine) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }
}

/// Tracks the typical recent amplitude. A median prevents one transient from
/// setting the gain without imposing a level threshold or quantizing the result.
private struct RecentLevelEstimator {
    private static let historyCapacity = 5

    private var history = [Float](repeating: 0, count: historyCapacity)
    private var sortedHistory = [Float](repeating: 0, count: historyCapacity)
    private var historyCount = 0
    private var historyIndex = 0

    mutating func update(with level: Float) -> Float {
        history[historyIndex] = level
        historyIndex = (historyIndex + 1) % Self.historyCapacity
        historyCount = min(historyCount + 1, Self.historyCapacity)

        for index in 0..<historyCount {
            sortedHistory[index] = history[index]
        }
        for index in 1..<historyCount {
            let level = sortedHistory[index]
            var insertionIndex = index
            while insertionIndex > 0 && sortedHistory[insertionIndex - 1] > level {
                sortedHistory[insertionIndex] = sortedHistory[insertionIndex - 1]
                insertionIndex -= 1
            }
            sortedHistory[insertionIndex] = level
        }
        return sortedHistory[(historyCount - 1) / 2]
    }

    mutating func reset() {
        historyCount = 0
        historyIndex = 0
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
