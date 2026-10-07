import Foundation

/// Levels audio to a consistent RMS from its recent measured amplitude.
enum SpeechAudioNormalizer {
    static let targetRMS: Float = 0.1

    static func normalize(_ samples: inout [Float], sampleRate: Double, strength: Float = 1,
                          timing: NormalizationSettings.Timing = .init()) {
        let normalizer = LookaheadSpeechNormalizer(sampleRate: sampleRate, strength: strength, timing: timing)
        var processed = samples.withUnsafeBufferPointer { buffer in
            guard let samples = buffer.baseAddress else { return [Float]() }
            return normalizer.process(samples, count: buffer.count)
        }
        processed.append(contentsOf: normalizer.finish()[0])
        samples = processed
    }

    static func gain(forMeasuredRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 1 }
        return targetRMS / rms
    }
}

/// Streaming audio leveling driven by fixed-size analysis frames and a short
/// recent-level window. Without isolation, every nonzero amplitude contributes
/// and gain remains unrestricted. RNNoise confidence selects analysis frames when
/// supplied; the last speech gain is held across weak phonemes and short pauses.
struct StreamingSpeechLeveler {
    private let strength: Float
    private let sampleRate: Double
    private let analysisFrameSize: Int
    private var analysisSampleCount = 0
    private var analysisSquareSum: Double = 0
    private var analysisSpeechEvidence: Float = 0
    private var hasAcquiredLevel = false
    private var acquisitionSamplesRemaining = 0
    private let acquisitionCoefficient: Float
    private let startupRampSampleCount: Int

    private var levelEstimator = RecentLevelEstimator()
    private var desiredGain: Float = 1
    private var appliedGain: Float = 1
    private var speechConfidence: Float = 1
    private var usesSpeechConfidence = false
    private let confidenceReleaseCoefficient: Float
    private var rumbleFilters: [SpeechRumbleFilter]
    private var limiters: [SpeechTransientLimiter]

    private static let gainReductionTimeConstant: Double = 0.008
    private static let gainRecoveryTimeConstant: Double = 0.05
    private let gainReductionCoefficient: Float
    private let gainRecoveryCoefficient: Float

    init(sampleRate: Double, strength: Float = 1, timing: NormalizationSettings.Timing = .init()) {
        self.strength = NormalizationSettings.validatedStrength(strength)
        let safeSampleRate = max(sampleRate, 1)
        self.sampleRate = safeSampleRate
        analysisFrameSize = max(1, Int(safeSampleRate * timing.lookaheadSeconds))
        startupRampSampleCount = max(1, Int(safeSampleRate * timing.startupRampSeconds))
        // Reach about 99% of the target within the selected ramp duration.
        acquisitionCoefficient = Float(exp(-5 / (safeSampleRate * timing.startupRampSeconds)))
        gainReductionCoefficient = Float(
            exp(-1 / (safeSampleRate * Self.gainReductionTimeConstant))
        )
        gainRecoveryCoefficient = Float(
            exp(-1 / (safeSampleRate * Self.gainRecoveryTimeConstant))
        )
        confidenceReleaseCoefficient = Float(exp(-1 / (safeSampleRate * 0.25)))
        rumbleFilters = [SpeechRumbleFilter(sampleRate: safeSampleRate)]
        limiters = [SpeechTransientLimiter(sampleRate: safeSampleRate)]
    }

    mutating func process(
        _ samples: UnsafeMutablePointer<Float>, count: Int, speechProbability: Float? = nil
    ) {
        guard count > 0 else { return }

        if speechProbability != nil, !usesSpeechConfidence {
            usesSpeechConfidence = true
            speechConfidence = 0
        }
        let confidence = speechProbability.map {
            $0.isFinite ? min(max(($0 - 0.2) / 0.6, 0), 1) : 0
        }
        for index in 0..<count {
            if let confidence {
                speechConfidence = max(confidence, speechConfidence * confidenceReleaseCoefficient)
            }
            let input = samples[index].isFinite ? samples[index] : 0
            let sample = rumbleFilters[0].process(input)
            trackAnalysis(sampleSquare: Double(sample) * Double(sample), speechEvidence: confidence ?? 1)
            updateAppliedGain()
            samples[index] = limiters[0].process(sample * appliedGain)
        }
    }

    /// Uses one speech estimate for all channels so adaptive gain preserves balance;
    /// transient limiting remains independent per channel.
    mutating func process(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        speechProbabilities: UnsafePointer<Float>? = nil
    ) {
        guard channelCount > 0, frameCount > 0 else { return }
        ensureLimiterCount(channelCount)

        if speechProbabilities != nil, !usesSpeechConfidence {
            usesSpeechConfidence = true
            speechConfidence = 0
        }
        for frame in 0..<frameCount {
            var frameEvidence: Float = 1
            if let speechProbabilities {
                let probability = speechProbabilities[frame]
                frameEvidence = probability.isFinite ? min(max((probability - 0.2) / 0.6, 0), 1) : 0
                speechConfidence = max(frameEvidence, speechConfidence * confidenceReleaseCoefficient)
            }
            var squareSum: Double = 0
            for channel in 0..<channelCount {
                let input = channels[channel][frame].isFinite ? channels[channel][frame] : 0
                let sample = rumbleFilters[channel].process(input)
                channels[channel][frame] = sample
                squareSum += Double(sample) * Double(sample)
            }

            trackAnalysis(sampleSquare: squareSum / Double(channelCount), speechEvidence: frameEvidence)
            updateAppliedGain()

            for channel in 0..<channelCount {
                let sample = channels[channel][frame]
                channels[channel][frame] = limiters[channel].process(sample * appliedGain)
            }
        }
    }

    /// The owning lookahead buffer provides at most one fixed analysis frame.
    /// Measure and filter it once, then apply its correction from its first sample.
    mutating func processLookaheadFrame(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        speechProbabilities: UnsafePointer<Float>? = nil
    ) {
        guard channelCount > 0, frameCount > 0 else { return }
        precondition(frameCount <= analysisFrameSize && analysisSampleCount == 0)
        ensureLimiterCount(channelCount)
        if speechProbabilities != nil, !usesSpeechConfidence {
            usesSpeechConfidence = true
            speechConfidence = 0
        }
        for frame in 0..<frameCount {
            var evidence: Float = 1
            if let speechProbabilities {
                let probability = speechProbabilities[frame]
                evidence = probability.isFinite ? min(max((probability - 0.2) / 0.6, 0), 1) : 0
                speechConfidence = max(evidence, speechConfidence * confidenceReleaseCoefficient)
            }
            var squareSum: Double = 0
            for channel in 0..<channelCount {
                let input = channels[channel][frame].isFinite ? channels[channel][frame] : 0
                let filtered = rumbleFilters[channel].process(input)
                channels[channel][frame] = filtered
                squareSum += Double(filtered) * Double(filtered)
            }
            analysisSampleCount += 1
            analysisSquareSum += squareSum / Double(channelCount)
            analysisSpeechEvidence += evidence
        }
        updateEffectiveLevel()
        analysisSampleCount = 0
        analysisSquareSum = 0
        analysisSpeechEvidence = 0
        for frame in 0..<frameCount {
            updateAppliedGain()
            for channel in 0..<channelCount {
                channels[channel][frame] = limiters[channel].process(channels[channel][frame] * appliedGain)
            }
        }
    }

    mutating func process(_ samples: inout [Float]) {
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            process(baseAddress, count: buffer.count)
        }
    }

    private mutating func trackAnalysis(sampleSquare: Double, speechEvidence: Float) {
        analysisSampleCount += 1
        analysisSquareSum += sampleSquare
        analysisSpeechEvidence += speechEvidence

        if analysisSampleCount == analysisFrameSize {
            updateEffectiveLevel()
            analysisSampleCount = 0
            analysisSquareSum = 0
            analysisSpeechEvidence = 0
        }
    }

    private mutating func updateAppliedGain() {
        let coefficient: Float
        if acquisitionSamplesRemaining > 0 {
            coefficient = acquisitionCoefficient
            acquisitionSamplesRemaining -= 1
        } else {
            coefficient = desiredGain < appliedGain
                ? gainReductionCoefficient : gainRecoveryCoefficient
        }
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

        if usesSpeechConfidence {
            let evidence = analysisSpeechEvidence / Float(analysisSampleCount)
            if evidence <= 0.2 {
                // Do not learn the room's noise floor as a new quiet speech level.
                // Hold the last speech gain through weak consonants and short gaps.
                if speechConfidence <= 0.2 { resetToNeutral() }
                return
            }
        }

        let effectiveRMS = levelEstimator.update(with: rms)
        let gain = SpeechAudioNormalizer.gain(forMeasuredRMS: effectiveRMS)
        guard gain.isFinite else {
            resetToNeutral()
            return
        }
        // Learn both level and confidence only on supported speech frames.
        // Keep that correction through weak phonemes instead of recomputing a
        // smaller correction every time confidence drops. Low-confidence frames
        // never turn a noise-floor estimate into a new, stronger speech boost.
        let correctionStrength = gain > 1 && usesSpeechConfidence
            ? strength * speechConfidence : strength
        desiredGain = correctionStrength == 0 ? 1 : pow(gain, correctionStrength)
        if !hasAcquiredLevel {
            // Bootstrap from the first fixed analysis frame with a fast, smooth
            // acquisition ramp. Avoid both a weak opening syllable and a sudden
            // one-sample gain jump. No fixed boost or amplitude gate is imposed.
            acquisitionSamplesRemaining = startupRampSampleCount
            hasAcquiredLevel = true
        }
    }

    private mutating func resetToNeutral() {
        levelEstimator.reset()
        desiredGain = 1
        hasAcquiredLevel = false
        acquisitionSamplesRemaining = 0
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
