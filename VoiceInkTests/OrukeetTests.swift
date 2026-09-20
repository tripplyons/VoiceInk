import Foundation
import Testing
@testable import VoiceInk

struct OrukeetTests {
    @Test @MainActor func orukeetIsAnOfflineModelWithTwentyFiveLanguages() throws {
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "orukeet" } as? TranscribeCppModel
        )
        #expect(model.provider == .transcribeCpp)
        #expect(!model.supportsStreaming)
        #expect(model.supportedLanguages["auto"] != nil)
        #expect(model.supportedLanguages.count == 26)

        let artifact = try #require(TranscribeCppModelCatalog.artifact(for: model.name))
        #expect(artifact.architectureHint == "parakeet")
        // The export publishes no runtime ITN control, so leave the runtime default alone.
        #expect(artifact.enablesInverseTextNormalization == false)
        #expect(
            artifact.downloadURL.absoluteString
                == "https://huggingface.co/oruk/orukeet/resolve/debfb0d5423d4b0446361e0ea024e6891e23a249/orukeet-transcribe-cpp-Q8_0.gguf"
        )
    }

    // Opt in with VOICEINK_ORUKEET_AUDIO when running xcodebuild test.
    // Use a recording of "The quick brown fox jumps over the lazy dog."
    // This downloads the real model and keeps it installed for use in the app.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICEINK_ORUKEET_AUDIO"] != nil))
    @MainActor func downloadsAndTranscribesEnglishAudio() async throws {
        let audioPath = try #require(ProcessInfo.processInfo.environment["VOICEINK_ORUKEET_AUDIO"])
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "orukeet" } as? TranscribeCppModel
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
        print("Orukeet transcript: \(transcript)")
        #expect(transcript.lowercased().contains("quick brown fox"))
        #expect(transcript.lowercased().contains("lazy dog"))
    }
}
