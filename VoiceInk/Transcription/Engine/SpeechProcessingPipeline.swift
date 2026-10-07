import Foundation

/// One pass: resample to RNNoise's native rate, isolate, EQ, level, then resample
/// back. Own one instance per channel/recording and call finish before closing.
final class SpeechProcessingPipeline {
    private let isolation: RNNoiseVoiceIsolation?
    private let inputResampler: StreamingAudioResampler?
    private let outputResampler: StreamingAudioResampler?
    private var equalizer: MicrophoneEqualizer?
    private let applyNormalization: Bool
    private(set) var outputSpeechProbabilities = [Float]()
    private var currentSpeechProbability: Float = 1
    private let normalizer: LookaheadSpeechNormalizer?
    private let outputRatio: Double
    private var received = 0
    private var emitted = 0
    private var finished = false
    private var work = [Float](repeating: 0, count: RNNoiseVoiceIsolation.frameSize)
    private var result = [Float]()

    init(sampleRate: Double, outputSampleRate: Double? = nil, normalizationStrength: Float, isolationStrength: Float,
         blendMode: VoiceIsolationSettings.BlendMode = .linear,
         equalizerSettings: MicrophoneEqualizerSettings? = nil,
         applyNormalization: Bool = true,
         normalizationTiming: NormalizationSettings.Timing = .init(),
         isolationFactory: (Float, VoiceIsolationSettings.BlendMode) throws -> RNNoiseVoiceIsolation = {
             try RNNoiseVoiceIsolation(strength: $0, blendMode: $1)
         }) throws {
        self.applyNormalization = applyNormalization
        let outputRate = outputSampleRate ?? sampleRate
        outputRatio = outputRate / sampleRate
        let isolationStrength = VoiceIsolationSettings.validatedStrength(isolationStrength)
        let processingRate = isolationStrength > 0 ? RNNoiseVoiceIsolation.sampleRate : sampleRate
        // Zero bypasses model allocation and inference, not merely the wet mix.
        isolation = isolationStrength > 0 ? try isolationFactory(isolationStrength, blendMode) : nil
        inputResampler = isolationStrength > 0 && sampleRate != processingRate
            ? StreamingAudioResampler(inputRate: sampleRate, outputRate: processingRate) : nil
        outputResampler = outputRate != processingRate
            ? StreamingAudioResampler(inputRate: processingRate, outputRate: outputRate) : nil
        equalizer = equalizerSettings.flatMap { settings in
            settings.isEnabled ? MicrophoneEqualizer(settings: settings, sampleRate: processingRate, channelCount: 1) : nil
        }
        normalizer = applyNormalization
            ? LookaheadSpeechNormalizer(sampleRate: processingRate, strength: normalizationStrength,
                timing: normalizationTiming) : nil
        result.reserveCapacity(4096)
    }

    /// Returned audio can be shorter than input while the isolation frame fills.
    func process(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {
        guard !finished, count > 0 else { return [] }
        result.removeAll(keepingCapacity: true)
        outputSpeechProbabilities.removeAll(keepingCapacity: true)
        received += count
        if let isolation {
            if let inputResampler {
                inputResampler.process(samples, count: count) { sample in
                    isolation.process(sample, emit: self.processIsolatedFrame)
                }
            } else {
                for index in 0..<count { isolation.process(samples[index], emit: processIsolatedFrame) }
            }
        } else {
            var offset = 0
            while offset < count {
                let length = min(work.count, count - offset)
                for index in 0..<length { work[index] = samples[offset + index] }
                processWork(count: length, probability: nil)
                offset += length
            }
        }
        return result
    }

    func finish() -> [Float] {
        guard !finished else { return [] }
        finished = true
        result.removeAll(keepingCapacity: true)
        outputSpeechProbabilities.removeAll(keepingCapacity: true)
        if let isolation {
            inputResampler?.finish { isolation.process($0, emit: self.processIsolatedFrame) }
            isolation.finish(emit: processIsolatedFrame)
        }
        if let normalizer {
            emitProcessed(normalizer.finish()[0], probabilities: normalizer.outputSpeechProbabilities)
        }
        outputResampler?.finish(emit: appendOutput)
        return result
    }

    private func processIsolatedFrame(_ samples: UnsafePointer<Float>, _ count: Int, _ probability: Float) {
        for index in 0..<count { work[index] = samples[index] }
        processWork(count: count, probability: probability)
    }

    private func processWork(count: Int, probability: Float?) {
        work.withUnsafeMutableBufferPointer { buffer in
            let samples = buffer.baseAddress!
            equalizer?.process(samples, count: count, channel: 0)
            if let normalizer {
                let processed = normalizer.process(samples, count: count, speechProbability: probability)
                emitProcessed(processed, probabilities: normalizer.outputSpeechProbabilities)
            } else {
                currentSpeechProbability = probability ?? 1
                for index in 0..<count { emitSample(samples[index]) }
            }
        }
    }

    private func emitProcessed(_ samples: [Float], probabilities: [Float]) {
        precondition(samples.count == probabilities.count)
        for index in samples.indices {
            currentSpeechProbability = probabilities[index]
            emitSample(samples[index])
        }
    }

    private func emitSample(_ sample: Float) {
        if let outputResampler { outputResampler.process(sample, emit: appendOutput) }
        else { appendOutput(sample) }
    }

    private func appendOutput(_ sample: Float) {
        guard emitted < Int(ceil(Double(received) * outputRatio)) else { return }
        // Resampling can overshoot slightly after peak protection.
        let finiteSample = sample.isFinite ? sample : 0
        result.append(applyNormalization ? min(max(finiteSample, -0.95), 0.95) : finiteSample)
        outputSpeechProbabilities.append(currentSpeechProbability)
        emitted += 1
    }
}
