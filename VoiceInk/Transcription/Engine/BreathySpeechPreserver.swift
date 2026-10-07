import Foundation

/// Restore a bounded amount of high-frequency detail suppressed by RNNoise
/// near detected speech. This protects unvoiced consonants without adding rumble
/// or restoring steady hiss throughout a recording. Blend endpoints stay exact.
struct BreathySpeechPreserver {
    private let amount: Float
    private let releaseCoefficient: Float
    private var support: Float = 0
    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    init(sampleRate: Double, isolationStrength: Float) {
        let rate = max(sampleRate, 1)
        let strength = VoiceIsolationSettings.validatedStrength(isolationStrength)
        amount = 0.8 * strength * (1 - strength) // At most 20% of the removed detail.
        releaseCoefficient = Float(exp(-1 / (rate * 0.15)))
        let frequency = min(1_500, rate * 0.45)
        let omega = 2 * Double.pi * frequency / rate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * sqrt(0.5))
        let a0 = 1 + alpha
        b0 = Float(((1 + cosine) / 2) / a0)
        b1 = Float(-(1 + cosine) / a0)
        b2 = b0
        a1 = Float(-2 * cosine / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func process(original: Float, isolated: Float, blended: Float, speechProbability: Float) -> Float {
        guard amount > 0 else { return blended }
        let evidence = speechProbability.isFinite ? min(max((speechProbability - 0.2) / 0.6, 0), 1) : 0
        support = max(evidence, support * releaseCoefficient)
        let residual = original - isolated
        let detail = b0 * residual + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = residual
        y2 = y1
        y1 = detail
        return blended + amount * support * detail
    }
}
