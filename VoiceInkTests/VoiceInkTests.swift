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

    private func phraseAction(_ phrase: String, autoEnd: Bool = false) -> SpokenPhraseAction {
        SpokenPhraseAction(
            phrase: phrase,
            shortcut: .key(keyCode: 36, modifierFlags: [.command]),
            endsDictationAutomatically: autoEnd
        )
    }

    @Test func peakNormalizesQuietAudioFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("quiet.wav")
        var samples = [Float](repeating: 0.05, count: 131_072)
        samples[100_000] = -0.2

        let processor = AudioProcessor()
        try processor.saveSamplesAsWav(samples: samples, to: url)
        let peakBefore = try peakAmplitude(in: url)

        try processor.normalizeAudioFile(at: url)
        let peakAfter = try peakAmplitude(in: url)
        let normalizedBackgroundSample = try sample(at: 0, in: url)

        #expect(peakBefore > 0.19 && peakBefore < 0.21)
        #expect(peakAfter > 0.99 && peakAfter <= 1.0)
        #expect(normalizedBackgroundSample > 0.24 && normalizedBackgroundSample < 0.26)
    }

    private func peakAmplitude(in url: URL) throws -> Float {
        let samples = try readSamples(from: url)
        return samples.lazy.map(abs).max() ?? 0
    }

    private func sample(at index: Int, in url: URL) throws -> Float {
        try readSamples(from: url)[index]
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
