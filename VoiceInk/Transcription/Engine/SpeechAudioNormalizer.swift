import Foundation

/// Levels speech from recent effective loudness without letting silence or an
/// isolated peak determine the gain for the rest of a recording.
enum SpeechAudioNormalizer {
    static let targetRMS: Float = 0.1
    static let minimumNormalizationGain: Float = 0.2
    static let maximumNormalizationGain: Float = 16
    static let targetLevelDB: Float = 20 * Float(log10(Double(targetRMS)))
    static let minimumNormalizationGainDB: Float =
        20 * Float(log10(Double(minimumNormalizationGain)))
    static let maximumNormalizationGainDB: Float =
        20 * Float(log10(Double(maximumNormalizationGain)))

    static func normalize(_ samples: inout [Float], sampleRate: Double) {
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate)
        leveler.process(&samples)
    }

    static func decibels(forRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return -160 }
        return 20 * Float(log10(Double(rms)))
    }

    static func gain(forLevelDifferenceDB difference: Float) -> Float {
        let boundedDifference = min(
            max(difference, minimumNormalizationGainDB),
            maximumNormalizationGainDB
        )
        return linearGain(forDecibels: boundedDifference)
    }

    static func linearGain(forDecibels decibels: Float) -> Float {
        Float(pow(10, Double(decibels) / 20))
    }
}

/// Streaming speech leveling driven by fixed-size analysis frames and a short
/// effective-level envelope. Gain reduction is quick; gain recovery is short but
/// smooth enough to avoid pumping after ordinary speech variation.
struct StreamingSpeechLeveler {
    private let sampleRate: Double
    private let analysisFrameSize: Int
    private var analysisSampleCount = 0
    private var analysisSquareSum: Double = 0
    private var analysisPeak: Float = 0

    private var speechLevelEstimator = RecentSpeechLevelEstimator()
    private var desiredGain: Float = 1
    private var appliedGain: Float = 1
    private var speechGateIsOpen = false
    private var framesAboveSpeechGate = 0
    private var belowSpeechGateDuration = 0.0
    private var recentSpeechPeak: Float = 0.01
    private var rumbleFilters: [SpeechRumbleFilter]
    private var limiters: [SpeechTransientLimiter]

    private let speechGateOpenRMS: Float = 0.0025
    private let speechGateCloseRMS: Float = 0.0022
    private let speechGateOpenFrameCount = 3
    private let speechGateHangover: Double = 0.08
    private static let gainReductionTimeConstant: Double = 0.008
    private static let gainRecoveryTimeConstant: Double = 0.05
    private let gainReductionCoefficient: Float
    private let gainRecoveryCoefficient: Float

    init(sampleRate: Double) {
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
            trackAnalysis(sampleSquare: Double(sample) * Double(sample), peak: abs(sample))
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
            var peak: Float = 0
            for channel in 0..<channelCount {
                let sample = rumbleFilters[channel].process(channels[channel][frame])
                channels[channel][frame] = sample
                squareSum += Double(sample) * Double(sample)
                peak = max(peak, abs(sample))
            }

            trackAnalysis(
                sampleSquare: squareSum / Double(channelCount),
                peak: peak
            )
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

    private mutating func trackAnalysis(sampleSquare: Double, peak: Float) {
        analysisSampleCount += 1
        analysisSquareSum += sampleSquare
        analysisPeak = max(analysisPeak, peak)

        if analysisSampleCount == analysisFrameSize {
            updateEffectiveLevel()
            analysisSampleCount = 0
            analysisSquareSum = 0
            analysisPeak = 0
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

        let duration = Double(analysisSampleCount) / sampleRate
        let rms = Float(sqrt(analysisSquareSum / Double(analysisSampleCount)))
        let peak = analysisPeak
        guard rms.isFinite, peak.isFinite else {
            resetToNeutral()
            return
        }

        let crestFactor = peak / max(rms, 0.000_001)
        let isIsolatedTransient = crestFactor > 15
            && SpeechAudioNormalizer.decibels(forRMS: peak)
                - SpeechAudioNormalizer.decibels(forRMS: max(recentSpeechPeak, 0.000_001)) > 10

        updateSpeechGate(rms: rms, duration: duration, isTransient: isIsolatedTransient)

        // A single high-crest frame is left to the limiter. It must not lower the
        // gain for the following speech, and it must not open the speech gate.
        if isIsolatedTransient {
            return
        }

        guard speechGateIsOpen else {
            resetToNeutral()
            recentSpeechPeak = ema(
                recentSpeechPeak,
                toward: 0.01,
                duration: duration,
                timeConstant: 0.25
            )
            return
        }

        // Keep the previous target through short gaps between words. Once the
        // gate closes, unity gain is requested so background noise is not boosted.
        guard rms >= speechGateCloseRMS else { return }

        let measuredLevelDB = SpeechAudioNormalizer.decibels(forRMS: rms)
        let effectiveSpeechLevelDB = speechLevelEstimator.update(with: measuredLevelDB)
        recentSpeechPeak = ema(
            recentSpeechPeak,
            toward: max(peak, 0.000_001),
            duration: duration,
            timeConstant: 0.25
        )

        let gainDifferenceDB = SpeechAudioNormalizer.targetLevelDB - effectiveSpeechLevelDB
        desiredGain = SpeechAudioNormalizer.gain(forLevelDifferenceDB: gainDifferenceDB)
    }

    private mutating func updateSpeechGate(
        rms: Float,
        duration: Double,
        isTransient: Bool
    ) {
        if isTransient {
            return
        }

        if speechGateIsOpen {
            if rms < speechGateCloseRMS {
                belowSpeechGateDuration += duration
                if belowSpeechGateDuration >= speechGateHangover {
                    speechGateIsOpen = false
                    framesAboveSpeechGate = 0
                }
            } else {
                belowSpeechGateDuration = 0
            }
            return
        }

        belowSpeechGateDuration = 0
        if rms >= speechGateOpenRMS {
            framesAboveSpeechGate += 1
            if framesAboveSpeechGate >= speechGateOpenFrameCount {
                speechGateIsOpen = true
            }
        } else {
            framesAboveSpeechGate = 0
        }
    }

    private mutating func resetToNeutral() {
        speechLevelEstimator.reset()
        desiredGain = 1
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

/// Tracks the typical level over a short speech window. A median ignores isolated
/// loud frames, while a confirmed level step resets the window so a real change in
/// speaking distance does not remain biased by the previous volume.
private struct RecentSpeechLevelEstimator {
    private static let historyCapacity = 15
    private static let stepThresholdDB: Float = 6
    private static let louderStepConfirmationFrames = 2
    private static let quieterStepConfirmationFrames = 3
    private static let minimumLevelDB: Float = -80
    private static let binWidthDB: Float = 2
    private static let binCount = 41

    private var history = [UInt8](repeating: 0, count: historyCapacity)
    private var histogram = [UInt8](repeating: 0, count: binCount)
    private var historyCount = 0
    private var historyIndex = 0
    private var pendingStepCount = 0
    private var pendingStepSum: Float = 0
    private var pendingStepDirection = 0

    mutating func update(with levelDB: Float) -> Float {
        guard historyCount > 0 else {
            append(levelDB)
            return medianHistoryLevel()
        }

        let currentLevelDB = medianHistoryLevel()
        let difference = levelDB - currentLevelDB
        guard abs(difference) >= Self.stepThresholdDB else {
            clearPendingStep()
            append(levelDB)
            return medianHistoryLevel()
        }

        let direction = difference > 0 ? 1 : -1
        if direction != pendingStepDirection {
            clearPendingStep()
            pendingStepDirection = direction
        }
        pendingStepCount += 1
        pendingStepSum += levelDB

        let requiredFrames = direction > 0
            ? Self.louderStepConfirmationFrames
            : Self.quieterStepConfirmationFrames
        guard pendingStepCount >= requiredFrames else {
            return direction > 0 ? levelDB : currentLevelDB
        }

        let confirmedLevelDB = pendingStepSum / Float(pendingStepCount)
        reset()
        for _ in 0..<requiredFrames {
            append(confirmedLevelDB)
        }
        return medianHistoryLevel()
    }

    mutating func reset() {
        for index in histogram.indices {
            histogram[index] = 0
        }
        historyCount = 0
        historyIndex = 0
        clearPendingStep()
    }

    private mutating func append(_ levelDB: Float) {
        let bin = levelBin(for: levelDB)
        if historyCount == Self.historyCapacity {
            let expiredBin = Int(history[historyIndex])
            histogram[expiredBin] -= 1
        } else {
            historyCount += 1
        }

        history[historyIndex] = UInt8(bin)
        histogram[bin] += 1
        historyIndex = (historyIndex + 1) % Self.historyCapacity
    }

    private mutating func clearPendingStep() {
        pendingStepCount = 0
        pendingStepSum = 0
        pendingStepDirection = 0
    }

    private func levelBin(for levelDB: Float) -> Int {
        let bin = Int((levelDB - Self.minimumLevelDB) / Self.binWidthDB)
        return min(max(bin, 0), Self.binCount - 1)
    }

    private func medianHistoryLevel() -> Float {
        let medianRank = (historyCount - 1) / 2
        var cumulativeCount = 0
        for bin in 0..<Self.binCount {
            cumulativeCount += Int(histogram[bin])
            if cumulativeCount > medianRank {
                return Self.minimumLevelDB + (Float(bin) + 0.5) * Self.binWidthDB
            }
        }
        return SpeechAudioNormalizer.targetLevelDB
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
