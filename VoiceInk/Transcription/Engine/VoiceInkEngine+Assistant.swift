import Foundation

@MainActor
extension VoiceInkEngine {
    func sendAssistantFollowUp(_ text: String, transcription: Transcription? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let assistantChat,
            let provider = assistantSession.provider
        else {
            return
        }

        let modelName = assistantSession.modelName
        let promptName = assistantSession.promptName
        let systemPrompt = assistantSession.systemPrompt
        let userMessage = assistantSession.beginFollowUp(trimmed)

        do {
            let reply = try await assistantChat.requestAssistantReply(
                provider: provider,
                modelName: modelName,
                systemPrompt: systemPrompt,
                messages: assistantSession.messages
            )

            guard assistantSession.hasMessage(id: userMessage.id),
                assistantSession.provider == provider
            else {
                return
            }

            assistantSession.finishFollowUp(reply.text)

            if let transcription {
                assistantChat.applyAssistantTurn(
                    transcription: transcription,
                    response: reply,
                    provider: provider,
                    modelName: modelName,
                    promptName: promptName
                )
            }
        } catch {
            guard assistantSession.hasMessage(id: userMessage.id),
                assistantSession.provider == provider
            else {
                return
            }
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            assistantSession.fail(errorDescription)
        }
    }

    func completeAssistantResponse(
        _ response: String,
        systemPrompt: String?
    ) async {
        assistantSession.finishInitialResponse(response, systemPrompt: systemPrompt)
    }
}
