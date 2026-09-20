import Foundation
import Testing
@testable import VoiceInk

struct OpenRouterTests {
    @Test @MainActor func maiTranscribeIsRegisteredAsAnOpenRouterCloudModel() throws {
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "microsoft/mai-transcribe-2" } as? CloudModel
        )
        #expect(model.provider == .openRouter)
        #expect(model.isMultilingualModel)
        #expect(model.supportedLanguages["auto"] != nil)

        let provider = try #require(CloudProviderRegistry.provider(for: .openRouter))
        // The transcription provider shares the Keychain entry and settings row with the
        // OpenRouter enhancement provider, so the keys have to match.
        #expect(provider.providerKey == AIProvider.openRouter.rawValue)
    }

    @Test func environmentKeyIsUsedOnlyForProvidersThatDeclareOne() {
        let environment = ["OPENROUTER_API_KEY": "  sk-or-v1-from-environment  "]
        #expect(
            APIKeyManager.shared.environmentAPIKey(forProvider: "OpenRouter", environment: environment)
                == "sk-or-v1-from-environment"
        )
        #expect(APIKeyManager.shared.environmentAPIKey(forProvider: "Groq", environment: environment) == nil)
        #expect(
            APIKeyManager.shared.environmentAPIKey(
                forProvider: "OpenRouter",
                environment: ["OPENROUTER_API_KEY": "   "]
            ) == nil
        )
        #expect(APIKeyManager.shared.environmentAPIKey(forProvider: "OpenRouter", environment: [:]) == nil)
    }

    @Test func requestFormatFollowsTheAudioFileExtension() {
        #expect(OpenRouterTranscriptionClient.audioFormat(for: "recording.wav") == "wav")
        #expect(OpenRouterTranscriptionClient.audioFormat(for: "Recording.MP3") == "mp3")
        #expect(OpenRouterTranscriptionClient.audioFormat(for: "recording") == "wav")
    }

    @Test func customDictionaryBecomesAPhraseListWhenItHasTerms() throws {
        #expect(OpenRouterTranscriptionClient.phraseListOptions(for: []) == nil)
        #expect(OpenRouterTranscriptionClient.phraseListOptions(for: ["   ", ""]) == nil)

        let options = try #require(OpenRouterTranscriptionClient.phraseListOptions(for: [" VoiceInk ", "", "Orukeet"]))
        #expect(options["phrases"] as? [String] == ["VoiceInk", "Orukeet"])
    }

    @Test func keyVerificationUsesTheInferenceKeyEndpoint() {
        // /api/v1/key needs a provisioning key and rejects the inference keys users paste,
        // which silently kept the transcription model out of the Modes picker.
        #expect(
            OpenRouterTranscriptionClient.keyVerificationURL.absoluteString
                == "https://openrouter.ai/api/v1/auth/key"
        )
    }

    @Test func emptyKeyFailsVerificationWithoutACall() async {
        let result = await OpenRouterTranscriptionClient.verifyAPIKey("   ")
        #expect(!result.isValid)
        #expect(result.errorMessage != nil)
    }

    // Opt in with OPENROUTER_API_KEY and VOICEINK_OPENROUTER_AUDIO when running
    // xcodebuild test. Use a recording of "The quick brown fox jumps over the lazy dog."
    // This makes a real, billed OpenRouter request.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil
                && ProcessInfo.processInfo.environment["VOICEINK_OPENROUTER_AUDIO"] != nil
        )
    )
    func transcribesEnglishAudioThroughOpenRouter() async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"])
        let audioPath = try #require(ProcessInfo.processInfo.environment["VOICEINK_OPENROUTER_AUDIO"])
        let audioURL = URL(fileURLWithPath: audioPath)

        let verification = await OpenRouterTranscriptionClient.verifyAPIKey(apiKey)
        #expect(verification.isValid)

        let transcript = try await OpenRouterProvider().transcribe(
            audioData: try Data(contentsOf: audioURL),
            fileName: audioURL.lastPathComponent,
            apiKey: apiKey,
            model: "microsoft/mai-transcribe-2",
            language: "en",
            customVocabulary: []
        )
        print("OpenRouter transcript: \(transcript)")
        #expect(transcript.lowercased().contains("quick brown fox"))
        #expect(transcript.lowercased().contains("lazy dog"))
    }
}
