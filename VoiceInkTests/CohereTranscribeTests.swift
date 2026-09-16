import Foundation
import Testing
@testable import VoiceInk

struct CohereTranscribeTests {
    @Test @MainActor func cohereTranscribeIsABatchModelWithFourteenLanguages() throws {
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "cohere-transcribe-03-2026" }
                as? FluidAudioModel
        )

        #expect(model.provider == .fluidAudio)
        #expect(!model.supportsStreaming)
        #expect(!TranscriptionRealtimeSupport.isAvailable(for: model))
        #expect(Set(model.supportedLanguages.keys) == [
            "ar", "de", "el", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "vi", "zh",
        ])
        #expect(FluidAudioModelManager.isCohereTranscribeModel(named: model.name))
    }
}
