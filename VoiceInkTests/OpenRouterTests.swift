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

    @Test @MainActor func grokSTTIsRegisteredAsAnOpenRouterCloudModel() throws {
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "x-ai/grok-stt-1.0" } as? CloudModel
        )
        #expect(model.provider == .openRouter)
        #expect(model.isMultilingualModel)
        #expect(model.supportedLanguages["auto"] != nil)
    }

    @Test @MainActor func scribeV2IsRegisteredAsAnOpenRouterCloudModel() throws {
        let model = try #require(
            TranscriptionModelRegistry.models.first { $0.name == "elevenlabs/scribe-v2" } as? CloudModel
        )
        #expect(model.provider == .openRouter)
        #expect(model.displayName == "Scribe v2")
        #expect(model.isMultilingualModel)
        #expect(model.supportedLanguages["auto"] != nil)
    }

    @Test func scribeV2UsesTheSharedAudioPayloadWithoutAzureOptions() throws {
        let audio = Data([1, 2, 3])
        let payload = OpenRouterTranscriptionClient.requestPayload(
            audioData: audio,
            fileName: "recording.wav",
            model: "elevenlabs/scribe-v2",
            language: "en",
            customVocabulary: ["VoiceInk"]
        )
        #expect(payload["model"] as? String == "elevenlabs/scribe-v2")
        #expect(payload["language"] as? String == "en")
        #expect(payload["response_format"] as? String == "json")
        #expect(payload["provider"] == nil)
        let input = try #require(payload["input_audio"] as? [String: String])
        #expect(input == ["data": audio.base64EncodedString(), "format": "wav"])
    }

    @Test func phraseListIsSentOnlyToModelsRoutedToAzure() throws {
        let options = try #require(
            OpenRouterTranscriptionClient.providerOptions(model: "microsoft/mai-transcribe-2", customVocabulary: ["VoiceInk"])
        )
        let azure = try #require(options["azure"] as? [String: Any])
        let phraseList = try #require(azure["phraseList"] as? [String: Any])
        #expect(phraseList["phrases"] as? [String] == ["VoiceInk"])

        #expect(OpenRouterTranscriptionClient.providerOptions(model: "microsoft/mai-transcribe-2", customVocabulary: []) == nil)
        #expect(OpenRouterTranscriptionClient.providerOptions(model: "x-ai/grok-stt-1.0", customVocabulary: ["VoiceInk"]) == nil)
    }

    @Test func requestLeavesSamplingOptionsToTheRoutedProvider() {
        let payload = OpenRouterTranscriptionClient.requestPayload(
            audioData: Data([1, 2, 3]),
            fileName: "recording.wav",
            model: "x-ai/grok-stt-1.0",
            language: nil,
            customVocabulary: ["VoiceInk"]
        )
        #expect(Set(payload.keys) == ["model", "input_audio", "response_format"])
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
        ),
        arguments: ["microsoft/mai-transcribe-2", "x-ai/grok-stt-1.0", "elevenlabs/scribe-v2"]
    )
    func transcribesEnglishAudioThroughOpenRouter(model: String) async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"])
        let audioPath = try #require(ProcessInfo.processInfo.environment["VOICEINK_OPENROUTER_AUDIO"])
        let audioURL = URL(fileURLWithPath: audioPath)

        let verification = await OpenRouterTranscriptionClient.verifyAPIKey(apiKey)
        #expect(verification.isValid)

        let transcript = try await OpenRouterProvider().transcribe(
            audioData: try Data(contentsOf: audioURL),
            fileName: audioURL.lastPathComponent,
            apiKey: apiKey,
            model: model,
            language: "en",
            customVocabulary: []
        )
        print("OpenRouter \(model) transcript: \(transcript)")
        #expect(transcript.lowercased().contains("quick brown fox"))
        #expect(transcript.lowercased().contains("lazy dog"))
    }
}
