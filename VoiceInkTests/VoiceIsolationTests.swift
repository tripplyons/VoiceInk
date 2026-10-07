import AVFoundation
import Foundation
import Testing
@testable import VoiceInk

struct VoiceIsolationTests {
    @Test func strengthAndBlendModePersistAndValidate() throws {
        let suite = "VoiceIsolationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(VoiceIsolationSettings.loadStrength(from: defaults) == VoiceIsolationSettings.defaultStrength)
        #expect(VoiceIsolationSettings.loadBlendMode(from: defaults) == .linear)
        defaults.set(0.65, forKey: VoiceIsolationSettings.strengthKey)
        defaults.set("equalPower", forKey: VoiceIsolationSettings.blendModeKey)
        #expect(abs(VoiceIsolationSettings.loadStrength(from: defaults) - 0.65) < 0.000001)
        #expect(VoiceIsolationSettings.loadBlendMode(from: defaults) == .equalPower)
        defaults.set("unknown", forKey: VoiceIsolationSettings.blendModeKey)
        #expect(VoiceIsolationSettings.loadBlendMode(from: defaults) == .linear)
        #expect(VoiceIsolationSettings.validatedStrength(.nan) == VoiceIsolationSettings.defaultStrength)
        #expect(VoiceIsolationSettings.validatedStrength(-1) == 0)
        #expect(VoiceIsolationSettings.validatedStrength(2) == 1)
    }

    @Test func quietSpeechFactoryDefaultsDoNotOverrideSavedValues() throws {
        #expect(VoiceIsolationSettings.defaultStrength == 0)
        #expect(NormalizationSettings.defaultStrength == 1)
        #expect(NormalizationSettings.Timing().lookaheadMilliseconds == 10)
        #expect(NormalizationSettings.Timing().startupRampMilliseconds == 100)
        let suite = "QuietSpeechDefaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NormalizationSettings.loadStrength(from: defaults) == NormalizationSettings.defaultStrength)
        defaults.set(0.6, forKey: NormalizationSettings.strengthKey)
        defaults.set(0.8, forKey: VoiceIsolationSettings.strengthKey)
        #expect(abs(NormalizationSettings.loadStrength(from: defaults) - 0.6) < 0.000001)
        #expect(abs(VoiceIsolationSettings.loadStrength(from: defaults) - 0.8) < 0.000001)
        let mode = VoiceIsolationSettings.loadBlendMode(from: defaults)
        #expect(mode == .linear)
        let blended = mode.mix(original: 0.01, isolated: 0,
            strength: VoiceIsolationSettings.defaultStrength)
        #expect(abs(blended - 0.01) < 0.000001)
    }

    @Test func timingPersistsAndRejectsInvalidValues() throws {
        let suite = "NormalizationTiming-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NormalizationSettings.loadTiming(from: defaults) == .init())
        let timing = NormalizationSettings.Timing(lookaheadMilliseconds: 45, startupRampMilliseconds: 30)
        NormalizationSettings.saveTiming(timing, to: defaults)
        #expect(NormalizationSettings.loadTiming(from: defaults) == timing)
        let invalid = NormalizationSettings.Timing(lookaheadMilliseconds: .infinity, startupRampMilliseconds: .nan)
        #expect(invalid == .init())
        let bounded = NormalizationSettings.Timing(lookaheadMilliseconds: -10, startupRampMilliseconds: 500)
        #expect(bounded.lookaheadMilliseconds == 5 && bounded.startupRampMilliseconds == 100)
        let decoded = try JSONDecoder().decode(NormalizationSettings.Timing.self,
            from: Data("{\"lookaheadMilliseconds\":-5,\"startupRampMilliseconds\":900}".utf8))
        #expect(decoded.lookaheadMilliseconds == 5 && decoded.startupRampMilliseconds == 100)
        #expect(try JSONDecoder().decode(NormalizationSettings.Timing.self, from: Data("{}".utf8)) == .init())
        #expect(try JSONDecoder().decode(NormalizationSettings.Timing.self,
            from: JSONEncoder().encode(timing)) == timing)
    }

    @Test func currentMicrophoneSettingsAreFactoryDefaults() {
        let settings = MicrophoneEqualizerSettings()
        #expect(settings.isEnabled)
        #expect(settings.highPassFrequency == 300)
        #expect(settings.lowPassFrequency == 7_900)
        #expect(settings.bandGains.allSatisfy { $0 == 0 })
    }

    @Test func lookaheadMeasuresTheOpeningFrameBeforeEmittingIt() {
        let source = (0..<320).map { Float(sin(Double($0) * 0.0864)) * 0.0005 }
        let normalizer = LookaheadSpeechNormalizer(sampleRate: 16_000, strength: 1,
            timing: .init(lookaheadMilliseconds: 20, startupRampMilliseconds: 15))
        var output: [Float] = []
        source.withUnsafeBufferPointer {
            #expect(normalizer.process($0.baseAddress!, count: 319).isEmpty)
            output = normalizer.process($0.baseAddress! + 319, count: 1)
        }
        #expect(output.count == 320)
        #expect(rms(output) > 0.075 && rms(output) < 0.115)
        #expect(normalizer.finish()[0].isEmpty)
    }

    @Test func lookaheadTimingAndStartupRampChangeTheResponse() {
        let source = (0..<4_000).map { Float(sin(Double($0) * 0.0864)) * 0.0005 }
        var levels: [Float] = []
        for ramp in [1.0, 100] {
            let normalizer = LookaheadSpeechNormalizer(sampleRate: 16_000, strength: 1,
                timing: .init(lookaheadMilliseconds: 20, startupRampMilliseconds: ramp))
            var output = source.withUnsafeBufferPointer { normalizer.process($0.baseAddress!, count: $0.count) }
            output += normalizer.finish()[0]
            #expect(output.count == source.count)
            levels.append(rms(output.prefix(320)))
        }
        #expect(levels[0] > levels[1] * 2)
        for milliseconds in [5.0, 45, 100] {
            let normalizer = LookaheadSpeechNormalizer(sampleRate: 16_000, strength: 1,
                timing: .init(lookaheadMilliseconds: milliseconds))
            let size = Int(milliseconds * 16)
            source.withUnsafeBufferPointer {
                #expect(normalizer.process($0.baseAddress!, count: size - 1).isEmpty)
                #expect(normalizer.process($0.baseAddress! + size - 1, count: 1).count == size)
            }
        }
    }

    @Test func configurableLookaheadPreservesTailAndChunkIndependence() throws {
        let source = (0..<4_017).map { Float(sin(Double($0) * 0.17)) * 0.02 }
        for duration in [5.0, 20, 100] {
            let timing = NormalizationSettings.Timing(lookaheadMilliseconds: duration, startupRampMilliseconds: 25)
            let reference = try process(source, rate: 16_000, chunks: [source.count], timing: timing)
            let varied = try process(source, rate: 16_000, chunks: [1, 13, 127, 911], timing: timing)
            #expect(reference.count == source.count && varied.count == source.count)
            #expect(zip(reference, varied).allSatisfy { abs($0 - $1) < 0.000001 })
        }
        for count in [0, 1, 159, 320, 321] {
            let source = [Float](repeating: 0.001, count: count)
            let output = try process(source, rate: 16_000, chunks: [127])
            #expect(output.count == source.count)
        }
    }

    @Test func breathDetailPreservationIsSpeechAwareAndBandLimited() {
        func restored(frequency: Double, probability: Float, strength: Float = 0.45) -> (Float, Float) {
            var preserver = BreathySpeechPreserver(sampleRate: 48_000, isolationStrength: strength)
            var baseline: [Float] = []
            var restored: [Float] = []
            for index in 0..<24_000 {
                let original = Float(sin(2 * Double.pi * frequency * Double(index) / 48_000)) * 0.01
                let blended = (1 - strength) * original
                baseline.append(blended)
                restored.append(preserver.process(original: original, isolated: 0,
                    blended: blended, speechProbability: probability))
            }
            return (rms(baseline.suffix(12_000)), rms(restored.suffix(12_000)))
        }
        let breath = restored(frequency: 6_000, probability: 1)
        #expect(breath.1 > breath.0 * 1.2)
        let rumble = restored(frequency: 200, probability: 1)
        #expect(rumble.1 < rumble.0 * 1.01)
        let hiss = restored(frequency: 6_000, probability: 0)
        #expect(abs(hiss.1 - hiss.0) < 0.000001)
        var bypass = BreathySpeechPreserver(sampleRate: 48_000, isolationStrength: 0)
        var full = BreathySpeechPreserver(sampleRate: 48_000, isolationStrength: 1)
        #expect(bypass.process(original: 0.2, isolated: 0.1, blended: 0.2, speechProbability: 1) == 0.2)
        #expect(full.process(original: 0.2, isolated: 0.1, blended: 0.1, speechProbability: 1) == 0.1)
    }

    @Test func blendModesHaveExactEndpointsAndDifferentMidpoints() {
        for mode in VoiceIsolationSettings.BlendMode.allCases {
            #expect(mode.mix(original: 0.2, isolated: 0.4, strength: 0) == 0.2)
            #expect(mode.mix(original: 0.2, isolated: 0.4, strength: 1) == 0.4)
        }
        #expect(abs(VoiceIsolationSettings.BlendMode.linear.mix(original: 0.2, isolated: 0.4, strength: 0.5) - 0.3) < 0.000001)
        #expect(abs(VoiceIsolationSettings.BlendMode.equalPower.mix(original: 0.2, isolated: 0.4, strength: 0.5) - 0.6 / sqrt(2)) < 0.000001)
    }

    @Test func rnnoiseDrySignalIsAlignedAndTailIsPreserved() throws {
        for count in [0, 1, 159, 480, 481, 1_517] {
            let source = (0..<count).map { Float($0 % 97) / 100 }
            let isolator = try RNNoiseVoiceIsolation(strength: 0)
            var output: [Float] = []
            let emit: (UnsafePointer<Float>, Int, Float) -> Void = { pointer, length, _ in
                output += UnsafeBufferPointer(start: pointer, count: length)
            }
            for sample in source { isolator.process(sample, emit: emit) }
            isolator.finish(emit: emit)
            isolator.finish(emit: emit)
            #expect(output == source)
        }
    }

    @Test func pipelinePreservesLengthAndIgnoresChunkBoundaries() throws {
        for rate in [8_000.0, 16_000, 44_100, 48_000, 96_000] {
            let source = (0..<Int(rate * 0.15) + 17).map {
                Float(sin(Double($0) * 0.17)) * 0.08
            }
            let reference = try process(source, rate: rate, chunks: [source.count])
            let varied = try process(source, rate: rate, chunks: [1, 127, 911, 53])
            #expect(reference.count == source.count)
            #expect(varied.count == source.count)
            #expect(zip(reference, varied).allSatisfy { abs($0 - $1) < 0.000001 })
            #expect(reference.allSatisfy { $0.isFinite && abs($0) <= 0.95 })
        }
    }

    @Test func zeroIsolationNeverInitializesRNNoise() throws {
        struct UnexpectedInitialization: Error {}
        var initializations = 0
        let pipeline = try SpeechProcessingPipeline(sampleRate: 44_100, outputSampleRate: 16_000,
            normalizationStrength: 0.75, isolationStrength: 0,
            isolationFactory: { _, _ in
                initializations += 1
                throw UnexpectedInitialization()
            })
        let source = [Float](repeating: 0.001, count: 4_410)
        var output = source.withUnsafeBufferPointer { pipeline.process($0.baseAddress!, count: $0.count) }
        output += pipeline.finish()
        #expect(initializations == 0)
        #expect(output.count == 1_600)
        #expect(output.allSatisfy { $0.isFinite })
    }

    @Test func bypassMatchesNormalizationOnly() throws {
        var source = (0..<8_003).map { Float(sin(Double($0) * 0.17)) * 0.03 }
        let output = try process(source, rate: 16_000, chunks: [127, 911], isolation: 0)
        SpeechAudioNormalizer.normalize(&source, sampleRate: 16_000, strength: 1)
        #expect(output.count == source.count)
        #expect(zip(output, source).allSatisfy { abs($0 - $1) < 0.000001 })
    }

    @Test func normalizationAcquiresQuietSpeechFromTheFirstAnalysisFrame() {
        for amplitude: Float in [0.0005, 0.03] {
            var samples = (0..<1_280).map { Float(sin(Double($0) * 0.0864)) * amplitude }
            var leveler = StreamingSpeechLeveler(sampleRate: 16_000,
                timing: .init(lookaheadMilliseconds: 20, startupRampMilliseconds: 15))
            leveler.process(&samples)
            // The first 20 ms measure loudness. The following frame should already
            // be near target, rather than waiting through a 50 ms recovery ramp.
            let acquired = rms(samples[320..<640])
            #expect(acquired > 0.085 && acquired < 0.115)
            #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 0.95 })
        }
    }

    @Test func normalizationHoldsGainAcrossUncertainWhisperPhonemes() {
        let source = (0..<3_200).map { Float(sin(Double($0) * 0.0864)) * 0.001 }
        var leveler = StreamingSpeechLeveler(sampleRate: 16_000)
        var confident = source
        confident.withUnsafeMutableBufferPointer {
            leveler.process($0.baseAddress!, count: $0.count, speechProbability: 0.9)
        }
        var uncertain = source
        uncertain.withUnsafeMutableBufferPointer {
            leveler.process($0.baseAddress!, count: $0.count, speechProbability: 0.3)
        }
        #expect(rms(confident.suffix(1_600)) > 0.09)
        #expect(rms(uncertain) > 0.09 && rms(uncertain) < 0.11)
    }

    @Test func normalizationDoesNotLearnNoiseAsQuieterSpeech() {
        var leveler = StreamingSpeechLeveler(sampleRate: 16_000)
        var speech = (0..<3_200).map { Float(sin(Double($0) * 0.0864)) * 0.02 }
        speech.withUnsafeMutableBufferPointer {
            leveler.process($0.baseAddress!, count: $0.count, speechProbability: 0.9)
        }
        var quietNoise = (0..<32_000).map { Float(sin(Double($0) * 0.0864)) * 0.0001 }
        quietNoise.withUnsafeMutableBufferPointer {
            leveler.process($0.baseAddress!, count: $0.count, speechProbability: 0)
        }
        // The held speech gain should not climb toward a new noise-floor target.
        // Exclude the high-pass filter's transition from the previous speech.
        #expect(rms(quietNoise[320..<3_200]) < 0.001)
        #expect(rms(quietNoise.suffix(8_000)) < 0.0001)
    }

    @Test func normalizationBootstrapIsChunkIndependent() {
        let source = (0..<12_801).map { Float(sin(Double($0) * 0.0864)) * 0.0005 }
        var reference = source
        var referenceLeveler = StreamingSpeechLeveler(sampleRate: 16_000)
        referenceLeveler.process(&reference)
        var varied = source
        var variedLeveler = StreamingSpeechLeveler(sampleRate: 16_000)
        var offset = 0
        while offset < varied.count {
            let count = min(127, varied.count - offset)
            varied.withUnsafeMutableBufferPointer {
                variedLeveler.process($0.baseAddress! + offset, count: count)
            }
            offset += count
        }
        #expect(zip(reference, varied).allSatisfy { abs($0 - $1) < 0.000001 })
    }

    @Test func speechConfidencePreventsNoiseBoostButAllowsQuietSpeech() {
        let source = (0..<32_000).map { Float(sin(Double($0) * 0.0864)) * 0.001 }
        var noise = source
        var speech = source
        var noiseLeveler = StreamingSpeechLeveler(sampleRate: 16_000)
        var speechLeveler = StreamingSpeechLeveler(sampleRate: 16_000)
        noise.withUnsafeMutableBufferPointer {
            noiseLeveler.process($0.baseAddress!, count: $0.count, speechProbability: 0)
        }
        speech.withUnsafeMutableBufferPointer {
            speechLeveler.process($0.baseAddress!, count: $0.count, speechProbability: 1)
        }
        #expect(rms(noise.suffix(8_000)) < 0.001)
        #expect(rms(speech.suffix(8_000)) > 0.09)
        #expect(rms(speech.suffix(8_000)) < 0.11)
    }

    @Test func rnnoiseSuppressesStationaryNoise() throws {
        var seed: UInt32 = 1
        let source: [Float] = (0..<144_000).map { _ in
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return (Float(seed >> 8) / Float(0xFFFFFF) - 0.5) * 0.06
        }
        let output = try process(source, rate: 48_000, chunks: [480], strength: 0)
        #expect(output.count == source.count)
        #expect(rms(output.suffix(48_000)) < rms(source.suffix(48_000)) * 0.5)
    }

    @Test func resamplingRejectsFrequenciesAboveOutputNyquist() {
        let source = (0..<48_000).map { Float(sin(2 * Double.pi * 12_000 * Double($0) / 48_000)) }
        let resampler = StreamingAudioResampler(inputRate: 48_000, outputRate: 16_000)
        var output: [Float] = []
        source.withUnsafeBufferPointer { resampler.process($0.baseAddress!, count: $0.count) { output.append($0) } }
        resampler.finish { output.append($0) }
        #expect(output.count == 16_000)
        #expect(rms(output.dropFirst(100).dropLast(100)) < 0.01)
    }

    @Test func importedAudioPreservesDurationAndRemainsFinite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("import.wav")
        let source = (0..<32_017).map { Float(sin(Double($0) * 0.0864)) * 0.03 }
        let processor = AudioProcessor()
        try processor.saveSamplesAsWav(samples: source, to: url)
        for isolation: Float in [0, 1] {
            let output = try await processor.processAudioToSamples(url, strength: 1,
                isolationStrength: isolation, blendMode: .equalPower, normalizationTiming: .init())
            #expect(output.count == source.count)
            #expect(output.allSatisfy { $0.isFinite && abs($0) <= 0.95 })
        }
    }

    @Test func multichannelFileKeepsLinkedNormalizationAndFrameCount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100, channels: 2, interleaved: false))
        let frameCount: AVAudioFrameCount = 88_217
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(frameCount) {
            channels[0][frame] = Float(sin(Double(frame) * 0.03134)) * 0.03
            channels[1][frame] = channels[0][frame] * 0.5
        }
        for isolation: Float in [0, 1] {
            let url = directory.appendingPathComponent("stereo-\(isolation).wav")
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            try AudioProcessor().normalizeAudioFile(at: url, strength: 1, isolationStrength: isolation, normalizationTiming: .init())
            let processed = try AVAudioFile(forReading: url)
            #expect(processed.length == Int64(frameCount))
            #expect(processed.processingFormat.channelCount == 2)
            let output = try #require(AVAudioPCMBuffer(pcmFormat: processed.processingFormat, frameCapacity: frameCount))
            try processed.read(into: output)
            let data = try #require(output.floatChannelData)
            if isolation == 0 {
                let left = rms(UnsafeBufferPointer(start: data[0] + 44_100, count: 44_100))
                let right = rms(UnsafeBufferPointer(start: data[1] + 44_100, count: 44_100))
                #expect(abs(right / left - 0.5) < 0.001)
            }
            for channel in 0..<2 {
                #expect(UnsafeBufferPointer(start: data[channel], count: Int(frameCount)).allSatisfy { $0.isFinite })
            }
        }
    }

    private func process(_ source: [Float], rate: Double, chunks: [Int], isolation: Float = 1,
                         strength: Float = 1, timing: NormalizationSettings.Timing = .init()) throws -> [Float] {
        let pipeline = try SpeechProcessingPipeline(sampleRate: rate, normalizationStrength: strength,
            isolationStrength: isolation, normalizationTiming: timing)
        var output: [Float] = []
        var offset = 0
        var index = 0
        while offset < source.count {
            let length = min(chunks[index % chunks.count], source.count - offset)
            source.withUnsafeBufferPointer {
                output += pipeline.process($0.baseAddress! + offset, count: length)
            }
            offset += length
            index += 1
        }
        output += pipeline.finish()
        #expect(pipeline.finish().isEmpty)
        return output
    }

    private func rms<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        let values = Array(samples)
        return sqrt(values.reduce(0) { $0 + $1 * $1 } / Float(max(values.count, 1)))
    }
}
