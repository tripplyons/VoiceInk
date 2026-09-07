import Foundation
import Testing
@testable import VoiceInk

struct SenseVoiceTests {
    @Test @MainActor func senseVoiceIsAnOfflineModelWithFiveLanguages() throws {
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "sensevoice-small" } as? TranscribeCppModel
        )
        #expect(model.provider == .transcribeCpp)
        #expect(!model.supportsStreaming)
        #expect(Set(model.supportedLanguages.keys) == ["auto", "en", "ja", "ko", "yue", "zh"])
        #expect(TranscribeCppModelCatalog.artifact(for: model.name)?.enablesInverseTextNormalization == true)
    }

    // Opt in with TEST_RUNNER_VOICEINK_SENSEVOICE_AUDIO when running xcodebuild test.
    // Use a recording of "The quick brown fox jumps over the lazy dog."
    // This downloads the real model and keeps it installed for use in the app.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICEINK_SENSEVOICE_AUDIO"] != nil))
    @MainActor func downloadsAndTranscribesEnglishAudio() async throws {
        let audioPath = try #require(ProcessInfo.processInfo.environment["VOICEINK_SENSEVOICE_AUDIO"])
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "sensevoice-small" } as? TranscribeCppModel
        )
        let manager = TranscribeCppModelManager.shared
        await manager.downloadModel(model)
        #expect(manager.isModelDownloaded(model))

        let service = TranscribeCppTranscriptionService()
        defer { service.cleanup() }
        let transcript = try await service.transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            model: model,
            context: TranscriptionRequestContext(language: "en", prompt: nil)
        )
        print("SenseVoice transcript: \(transcript)")
        #expect(transcript.lowercased().contains("quick brown fox"))
        #expect(transcript.lowercased().contains("lazy dog"))
    }
}
