import AVFoundation
import Foundation
import Testing
@testable import VoiceInk

struct VoiceInkTests {
    @Test func spokenPhraseNormalizationIgnoresCasePunctuationAndWhitespace() {
        #expect(SpokenPhraseMatcher.normalized("  Re-Phrase, THIS! ") == "re phrase this")
    }

    @Test func spokenPhraseExactMatchRequiresTheWholeTranscription() {
        let action = phraseAction("Rephrase this")
        #expect(SpokenPhraseMatcher.exactMatch(in: "rephrase this!", actions: [action]) == action)
        #expect(SpokenPhraseMatcher.exactMatch(in: "please rephrase this", actions: [action]) == nil)
    }

    @Test func spokenPhraseSuffixMatchRemovesTheTrigger() {
        let action = phraseAction("send it", autoEnd: true)
        let match = SpokenPhraseMatcher.suffixMatch(in: "This is ready. SEND IT!", actions: [action])
        #expect(match == SpokenPhraseMatch(action: action, remainingText: "This is ready"))
    }

    @Test func spokenPhraseSuffixNeedsAnEnabledAutoEndAction() {
        var action = phraseAction("send it")
        #expect(SpokenPhraseMatcher.suffixMatch(in: "Text send it", actions: [action]) == nil)
        action.endsDictationAutomatically = true
        action.isEnabled = false
        #expect(SpokenPhraseMatcher.suffixMatch(in: "Text send it", actions: [action]) == nil)
    }

    @Test func spokenPhraseSuffixDoesNotMatchAPartialWord() {
        let action = phraseAction("finish", autoEnd: true)
        #expect(SpokenPhraseMatcher.suffixMatch(in: "Draft fin", actions: [action]) == nil)
        #expect(SpokenPhraseMatcher.suffixMatch(in: "Draft finishing", actions: [action]) == nil)
    }

    @Test func spokenPhraseTriggerDetectorFiresOnlyOnceUntilReset() {
        let action = phraseAction("finish", autoEnd: true)
        var detector = SpokenPhraseTriggerDetector()
        #expect(detector.matchPreview("Draft finish", actions: [action]) != nil)
        #expect(detector.matchPreview("Draft finish", actions: [action]) == nil)
        detector.reset()
        #expect(detector.matchPreview("Another finish", actions: [action]) != nil)
    }

    @MainActor
    @Test func spokenPhraseStorePersistsUpdatesAndRemoval() throws {
        let suite = "SpokenPhraseActionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let action = phraseAction("archive")
        let store = SpokenPhraseActionStore(defaults: defaults)
        store.add(action)
        #expect(SpokenPhraseActionStore(defaults: defaults).actions == [action])
        store.remove(id: action.id)
        #expect(SpokenPhraseActionStore(defaults: defaults).actions.isEmpty)
    }

    @Test func spokenPhraseActionPersistsStartingANewDictation() throws {
        var action = phraseAction("send and continue")
        action.startsNewDictationAutomatically = true

        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(SpokenPhraseAction.self, from: data)

        #expect(decoded == action)
    }

    @Test func spokenPhraseActionDefaultsNewDictationToOffForExistingData() throws {
        let action = phraseAction("send")
        let data = try JSONEncoder().encode(action)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "startsNewDictationAutomatically")
        let existingData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SpokenPhraseAction.self, from: existingData)

        #expect(!decoded.startsNewDictationAutomatically)
    }

    @Test func continuousModeUsesAnExplicitPushAction() throws {
        var action = phraseAction("push")
        action.operation = .pushStack
        let match = try #require(
            ContinuousVoiceCommandMatcher.match(
                in: "first thought push",
                actions: [action]
            )
        )

        #expect(match.command == .pushStack)
        #expect(match.remainingText == "first thought")
    }

    @Test func continuousModeMapsMultipleKeywordsToStackOperations() throws {
        var submitAction = phraseAction("send it")
        submitAction.operation = .submitStack
        var resetAction = phraseAction("start over")
        resetAction.operation = .resetStack

        let submit = try #require(
            ContinuousVoiceCommandMatcher.match(in: "send it", actions: [submitAction, resetAction])
        )
        let reset = try #require(
            ContinuousVoiceCommandMatcher.match(in: "start over", actions: [submitAction, resetAction])
        )

        #expect(submit.command == .submitStack)
        #expect(reset.command == .resetStack)
    }

    @Test func continuousModeUsesAutoEndSpokenActionsAsKeyboardCommands() throws {
        let action = phraseAction("press return", autoEnd: true)
        let match = try #require(
            ContinuousVoiceCommandMatcher.match(
                in: "send this press return",
                actions: [action]
            )
        )

        #expect(match.command == .runShortcut(action.shortcut))
        #expect(match.remainingText == "send this")
    }

    @Test func continuousModeSupportsSubmitAndShortcutAsOneAction() throws {
        var action = phraseAction("send and continue", autoEnd: true)
        action.operation = .submitStackAndKeyboardShortcut
        let match = try #require(
            ContinuousVoiceCommandMatcher.match(in: "draft send and continue", actions: [action])
        )

        #expect(match.command == .submitStackAndRunShortcut(action.shortcut))
        #expect(match.remainingText == "draft")
    }

    @Test func spokenActionOperationDefaultsToKeyboardShortcutForOlderSettings() throws {
        let action = phraseAction("press return", autoEnd: true)
        let data = try JSONEncoder().encode(action)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "operation")
        let decoded = try JSONDecoder().decode(
            SpokenPhraseAction.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.operation == .keyboardShortcut)
    }

    @Test func unknownSpokenActionOperationKeepsOlderActionUsable() throws {
        let action = phraseAction("press return", autoEnd: true)
        let data = try JSONEncoder().encode(action)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["operation"] = "futureOperation"
        let decoded = try JSONDecoder().decode(
            SpokenPhraseAction.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.operation == .keyboardShortcut)
    }

    @Test func continuousTextStackRetainsEntriesUntilSubmissionIsHandled() {
        var stack = ContinuousTextStack()
        stack.push(" first ")
        stack.push("second")

        #expect(stack.entries == ["first", "second"])
        #expect(stack.text == "first second")

        stack.reset()
        #expect(stack.isEmpty)
    }

    private func phraseAction(_ phrase: String, autoEnd: Bool = false) -> SpokenPhraseAction {
        SpokenPhraseAction(
            phrase: phrase,
            shortcut: .key(keyCode: 36, modifierFlags: [.command]),
            endsDictationAutomatically: autoEnd
        )
    }

    @MainActor
    @Test func microphoneEqualizerResetRestoresTunedDefaults() throws {
        let suite = "MicrophoneEqualizerResetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MicrophoneEqualizerSettingsStore(defaults: defaults)
        store.settings = MicrophoneEqualizerSettings(
            isEnabled: true,
            highPassFrequency: 200,
            bandGains: Array(repeating: 8, count: MicrophoneEqualizerSettings.bandFrequencies.count),
            lowPassFrequency: 4_000
        )

        store.reset()

        #expect(store.settings.isEnabled)
        #expect(store.settings.highPassFrequency == 110)
        #expect(store.settings.bandGains == [-9.5, -6.5, -3.5, -1, 1, 6, 6])
        #expect(store.settings.lowPassFrequency == 7_800)
    }

    @MainActor
    @Test func microphoneEqualizerSettingsPersist() throws {
        let suite = "MicrophoneEqualizerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MicrophoneEqualizerSettingsStore(defaults: defaults)
        store.settings = MicrophoneEqualizerSettings(
            isEnabled: true,
            highPassFrequency: 140,
            bandGains: [-2, 1, 3, 4, -1, -3],
            lowPassFrequency: 6_200
        )

        let restored = MicrophoneEqualizerSettingsStore(defaults: defaults).settings
        #expect(restored == store.settings)
    }

    @Test func microphoneEqualizerHighPassAttenuatesLowFrequencies() {
        let sampleRate = 16_000.0
        let settings = MicrophoneEqualizerSettings(
            isEnabled: true,
            highPassFrequency: 200,
            bandGains: Array(repeating: 0, count: MicrophoneEqualizerSettings.bandFrequencies.count),
            lowPassFrequency: 7_800
        )
        var lowTone = sineWave(frequency: 30, sampleRate: sampleRate)
        var voiceTone = sineWave(frequency: 1_000, sampleRate: sampleRate)
        let originalLowRMS = rms(lowTone.dropFirst(8_000))
        let originalVoiceRMS = rms(voiceTone.dropFirst(8_000))
        var lowEqualizer = MicrophoneEqualizer(settings: settings, sampleRate: sampleRate, channelCount: 1)
        var voiceEqualizer = MicrophoneEqualizer(settings: settings, sampleRate: sampleRate, channelCount: 1)

        lowEqualizer.process(&lowTone)
        voiceEqualizer.process(&voiceTone)

        #expect(rms(lowTone.dropFirst(8_000)) < originalLowRMS * 0.05)
        #expect(rms(voiceTone.dropFirst(8_000)) > originalVoiceRMS * 0.9)
    }

    @Test func microphoneEqualizerAppliesBandGain() {
        let sampleRate = 16_000.0
        let settings = MicrophoneEqualizerSettings(
            isEnabled: true,
            highPassFrequency: 40,
            bandGains: [0, 0, 0, 12, 0, 0],
            lowPassFrequency: 7_800
        )
        var tone = sineWave(frequency: 1_000, sampleRate: sampleRate, amplitude: 0.1)
        let originalRMS = rms(tone.dropFirst(8_000))
        var equalizer = MicrophoneEqualizer(settings: settings, sampleRate: sampleRate, channelCount: 1)

        equalizer.process(&tone)

        #expect(rms(tone.dropFirst(8_000)) > originalRMS * 3.5)
    }

    @Test func microphoneEqualizerPreservesStateAcrossLiveChunks() {
        let settings = MicrophoneEqualizerSettings(isEnabled: true)
        let source = zip(
            sineWave(frequency: 180, sampleRate: 16_000, amplitude: 0.25),
            sineWave(frequency: 2_300, sampleRate: 16_000, amplitude: 0.1)
        ).map { pair in pair.0 + pair.1 }
        var wholeBuffer = source
        var wholeEqualizer = MicrophoneEqualizer(settings: settings, sampleRate: 16_000, channelCount: 1)
        wholeEqualizer.process(&wholeBuffer)

        var chunkedEqualizer = MicrophoneEqualizer(settings: settings, sampleRate: 16_000, channelCount: 1)
        var chunkedOutput: [Float] = []
        for start in stride(from: 0, to: source.count, by: 257) {
            var chunk = Array(source[start..<min(start + 257, source.count)])
            chunkedEqualizer.process(&chunk)
            chunkedOutput.append(contentsOf: chunk)
        }

        let maximumDifference = zip(wholeBuffer, chunkedOutput).map { pair in
            abs(pair.0 - pair.1)
        }.max() ?? 0
        #expect(maximumDifference < 0.000_001)
    }

    @Test func microphoneProcessingNormalizesEqualizedAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("equalized.wav")
        let samples = [Float](repeating: 0, count: 4_000)
            + sineWave(frequency: 1_000, sampleRate: 16_000, amplitude: 0.05)
        let settings = MicrophoneEqualizerSettings(
            isEnabled: true,
            highPassFrequency: 80,
            bandGains: [0, 0, 0, 12, 0, 0],
            lowPassFrequency: 7_500
        )
        let processor = AudioProcessor()
        try processor.saveSamplesAsWav(samples: samples, to: url)

        try processor.processMicrophoneRecording(at: url, settings: settings)

        let processedSamples = try readSamples(from: url)
        let speechRMS = rms(processedSamples.suffix(12_000))
        #expect(speechRMS > 0.09 && speechRMS < 0.11)
        #expect((processedSamples.lazy.map(abs).max() ?? 0) <= 0.95)
    }

    @Test func normalizationStrengthControlsBoostAndAttenuation() {
        for amplitude: Float in [0.03, 0.25] {
            let source = sineWave(frequency: 220, sampleRate: 16_000, amplitude: amplitude, duration: 2)
            let levels = [Float(0), 0.5, 1].map { strength in
                var samples = source
                SpeechAudioNormalizer.normalize(&samples, sampleRate: 16_000, strength: strength)
                return rms(samples.suffix(16_000))
            }
            #expect(abs(levels[0] - rms(source.suffix(16_000))) < 0.005)
            if amplitude < 0.1 {
                #expect(levels[0] < levels[1] && levels[1] < levels[2])
            } else {
                #expect(levels[0] > levels[1] && levels[1] > levels[2])
            }
            #expect(levels[2] > 0.09 && levels[2] < 0.11)
        }
    }

    @Test func normalizationStrengthPersistsAndValidates() throws {
        let suiteName = "NormalizationStrengthTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(NormalizationSettings.loadStrength(from: defaults) == 1)
        defaults.set(0.35, forKey: NormalizationSettings.strengthKey)
        #expect(NormalizationSettings.loadStrength(from: defaults) == Float(0.35))
        defaults.set(2, forKey: NormalizationSettings.strengthKey)
        #expect(NormalizationSettings.loadStrength(from: defaults) == 1)
        defaults.set(-1, forKey: NormalizationSettings.strengthKey)
        #expect(NormalizationSettings.loadStrength(from: defaults) == 0)
        #expect(NormalizationSettings.validatedStrength(.nan) == 1)
    }

    @Test func speechNormalizationIgnoresIsolatedPeak() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("transient.wav")
        var samples = [Float](repeating: 0, count: 16_000)
        samples[1_000] = 0.95
        samples += sineWave(frequency: 220, sampleRate: 16_000, amplitude: 0.03, duration: 2)

        let processor = AudioProcessor()
        try processor.saveSamplesAsWav(samples: samples, to: url)
        try processor.normalizeAudioFile(at: url)

        let normalizedSamples = try readSamples(from: url)
        let speechRMS = rms(normalizedSamples.suffix(16_000))
        let peak = normalizedSamples.lazy.map(abs).max() ?? 0

        #expect(speechRMS > 0.09 && speechRMS < 0.105)
        #expect(peak <= 0.951)
    }

    @Test func streamingSpeechLevelerRecoversAfterTransient() {
        let sampleRate = 16_000.0
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate)
        let warmup = processInStreamingChunks(
            sineWave(frequency: 220, sampleRate: sampleRate, amplitude: 0.03),
            with: &leveler
        )

        var transient = [Float](repeating: 0, count: 320)
        transient[0] = 1
        let limitedTransient = processInStreamingChunks(transient, with: &leveler)
        let speechAfterTransient = processInStreamingChunks(
            sineWave(
                frequency: 220,
                sampleRate: sampleRate,
                amplitude: 0.03,
                duration: 0.5
            ),
            with: &leveler
        )

        #expect(rms(warmup.suffix(4_000)) > 0.075)
        #expect((limitedTransient.lazy.map(abs).max() ?? 0) <= 0.95)
        #expect(rms(speechAfterTransient.suffix(4_000)) > 0.075)
    }

    @Test func normalizationGainHasNoMinimumOrMaximum() {
        #expect(abs(SpeechAudioNormalizer.gain(forMeasuredRMS: 0.000_1) - 1_000) < 0.001)
        #expect(abs(SpeechAudioNormalizer.gain(forMeasuredRMS: 1) - 0.1) < 0.000_1)
    }

    @Test func streamingSpeechLevelerNormalizesVeryQuietAudioAtStartup() {
        let sampleRate = 16_000.0
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate)
        let quietAudio = sineWave(
            frequency: 220,
            sampleRate: sampleRate,
            amplitude: 0.000_5,
            duration: 0.75
        )
        let processed = processInStreamingChunks(quietAudio, with: &leveler)

        #expect(rms(processed.suffix(4_000)) > 0.09)
        #expect(rms(processed.suffix(4_000)) < 0.11)
    }

    @Test func streamingSpeechLevelerNormalizesAudioBelowFormerGate() {
        let sampleRate = 16_000.0
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate)
        let lowLevelAudio = sineWave(
            frequency: 220,
            sampleRate: sampleRate,
            amplitude: 0.003,
            duration: 0.75
        )
        let processed = processInStreamingChunks(lowLevelAudio, with: &leveler)

        #expect(rms(processed.suffix(4_000)) > 0.09)
        #expect(rms(processed.suffix(4_000)) < 0.11)
    }

    @Test func streamingSpeechLevelerTracksLowerAmplitudeWithoutGate() {
        let sampleRate = 16_000.0
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate)
        _ = processInStreamingChunks(
            sineWave(frequency: 220, sampleRate: sampleRate, amplitude: 0.03),
            with: &leveler
        )
        let lowLevelAudio = processInStreamingChunks(
            sineWave(frequency: 220, sampleRate: sampleRate, amplitude: 0.003),
            with: &leveler
        )

        #expect(rms(lowLevelAudio.suffix(4_000)) > 0.09)
        #expect(rms(lowLevelAudio.suffix(4_000)) < 0.11)
    }

    @Test func streamingSpeechLevelerRelaxesTowardNeutralDuringSilence() {
        let sampleRate = 16_000.0
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate)
        let quietSpeech = processInStreamingChunks(
            sineWave(frequency: 220, sampleRate: sampleRate, amplitude: 0.03),
            with: &leveler
        )
        _ = processInStreamingChunks(
            [Float](repeating: 0, count: Int(sampleRate * 3)),
            with: &leveler
        )
        let speechAtNewLevel = processInStreamingChunks(
            sineWave(
                frequency: 220,
                sampleRate: sampleRate,
                amplitude: 0.1,
                duration: 0.75
            ),
            with: &leveler
        )

        #expect(rms(quietSpeech.suffix(4_000)) > 0.075)
        #expect(rms(speechAtNewLevel.suffix(4_000)) > 0.09)
        #expect(rms(speechAtNewLevel.suffix(4_000)) < 0.11)
    }

    @Test func streamingSpeechLevelerTracksRecentSpeechWithoutSilence() {
        let sampleRate = 16_000.0
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate)
        _ = processInStreamingChunks(
            sineWave(frequency: 220, sampleRate: sampleRate, amplitude: 0.03),
            with: &leveler
        )
        let louderSpeech = processInStreamingChunks(
            sineWave(
                frequency: 220,
                sampleRate: sampleRate,
                amplitude: 0.16,
                duration: 4.5
            ),
            with: &leveler
        )

        #expect(rms(louderSpeech.suffix(4_000)) > 0.09)
        #expect(rms(louderSpeech.suffix(4_000)) < 0.11)
    }

    @Test func streamingSpeechLevelerRecoversQuicklyAfterLoudSpeech() {
        let sampleRate = 16_000.0
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate)
        _ = processInStreamingChunks(
            sineWave(frequency: 220, sampleRate: sampleRate, amplitude: 0.03),
            with: &leveler
        )
        let loudSpeech = processInStreamingChunks(
            sineWave(
                frequency: 220,
                sampleRate: sampleRate,
                amplitude: 0.65,
                duration: 0.25
            ),
            with: &leveler
        )
        let quietSpeechAfterLoud = processInStreamingChunks(
            sineWave(
                frequency: 220,
                sampleRate: sampleRate,
                amplitude: 0.03,
                duration: 0.5
            ),
            with: &leveler
        )

        #expect((loudSpeech.lazy.map(abs).max() ?? 0) <= 0.95)
        #expect(rms(quietSpeechAfterLoud.prefix(3_200)) > 0.035)
        #expect(rms(quietSpeechAfterLoud.suffix(3_200)) > 0.09)
        #expect(rms(quietSpeechAfterLoud.suffix(3_200)) < 0.105)
    }

    @Test func streamingSpeechLevelerReducesVeryLoudSpeechToTarget() {
        let sampleRate = 16_000.0
        var leveler = StreamingSpeechLeveler(sampleRate: sampleRate)
        let loudSpeech = processInStreamingChunks(
            sineWave(
                frequency: 220,
                sampleRate: sampleRate,
                amplitude: 0.65,
                duration: 0.75
            ),
            with: &leveler
        )

        #expect(rms(loudSpeech.suffix(4_000)) > 0.09)
        #expect(rms(loudSpeech.suffix(4_000)) < 0.11)
        #expect((loudSpeech.lazy.map(abs).max() ?? 0) <= 0.95)
    }

    @Test func streamingSpeechLevelerIgnoresCallbackBoundaries() {
        let source = sineWave(
            frequency: 220,
            sampleRate: 16_000,
            amplitude: 0.03,
            duration: 0.75
        ) + sineWave(
            frequency: 220,
            sampleRate: 16_000,
            amplitude: 0.65,
            duration: 0.25
        ) + sineWave(
            frequency: 220,
            sampleRate: 16_000,
            amplitude: 0.03,
            duration: 0.5
        ) + [0]
        var referenceLeveler = StreamingSpeechLeveler(sampleRate: 16_000)
        var variedLeveler = StreamingSpeechLeveler(sampleRate: 16_000)
        let reference = processInStreamingChunks(
            source,
            with: &referenceLeveler,
            chunkPattern: [320]
        )
        let varied = processInStreamingChunks(
            source,
            with: &variedLeveler,
            chunkPattern: [127, 911, 53, 4_096, 29]
        )

        let maximumDifference = zip(reference, varied).map { pair in
            abs(pair.0 - pair.1)
        }.max() ?? 0
        #expect(reference.count == source.count)
        #expect(varied.count == source.count)
        #expect(maximumDifference < 0.000_001)
    }

    private func processInStreamingChunks(
        _ samples: [Float],
        with leveler: inout StreamingSpeechLeveler,
        chunkSize: Int = 320
    ) -> [Float] {
        processInStreamingChunks(samples, with: &leveler, chunkPattern: [chunkSize])
    }

    private func processInStreamingChunks(
        _ samples: [Float],
        with leveler: inout StreamingSpeechLeveler,
        chunkPattern: [Int]
    ) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(samples.count)
        var start = 0
        var patternIndex = 0
        while start < samples.count {
            let chunkSize = chunkPattern[patternIndex % chunkPattern.count]
            let end = min(start + chunkSize, samples.count)
            var chunk = Array(samples[start..<end])
            leveler.process(&chunk)
            output += chunk
            start = end
            patternIndex += 1
        }
        return output
    }

    private func sineWave(
        frequency: Double,
        sampleRate: Double,
        amplitude: Float = 1,
        duration: Double = 1
    ) -> [Float] {
        (0..<Int(sampleRate * duration)).map { frame in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
        }
    }

    private func rms<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var count = 0
        for sample in samples {
            sum += sample * sample
            count += 1
        }
        return count > 0 ? sqrt(sum / Float(count)) : 0
    }

    private func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw AudioProcessor.AudioProcessingError.sampleExtractionFailed
        }

        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else {
            throw AudioProcessor.AudioProcessingError.sampleExtractionFailed
        }

        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }
}
