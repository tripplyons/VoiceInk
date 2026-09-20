import Foundation
import SwiftData

struct OpenRouterProvider: CloudProvider {
    let modelProvider: ModelProvider = .openRouter
    let providerKey: String = "OpenRouter"
    /// OpenRouter does not publish a per-model language list for its speech endpoint,
    /// so offer the full set and let the routed provider detect the language.
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = true

    var models: [CloudModel] {
        [
            CloudModel(
                name: "microsoft/mai-transcribe-2",
                displayName: "MAI-Transcribe 2",
                description: "Microsoft's speech-to-text model, billed through your OpenRouter account",
                provider: .openRouter,
                speed: 0.9,
                accuracy: 0.97,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .openRouter)
            )
        ]
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?, customVocabulary: [String]
    ) async throws -> String {
        try await OpenRouterTranscriptionClient.transcribe(
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: model,
            language: language,
            customVocabulary: customVocabulary
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await OpenRouterTranscriptionClient.verifyAPIKey(key)
    }
}

/// Client for OpenRouter's `/api/v1/audio/transcriptions` endpoint.
///
/// The endpoint takes a JSON body with base64 audio rather than the multipart form
/// used by the OpenAI-compatible providers, which is also what lets custom dictionary
/// terms through as an Azure phrase list.
enum OpenRouterTranscriptionClient {
    private static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    /// Unlike /v1/models, this endpoint requires authentication, so it can tell a working
    /// key from a rejected one. /v1/key is the key-management endpoint and needs a
    /// provisioning key, so it rejects the ordinary inference keys users paste here.
    static let keyVerificationURL = baseURL.appendingPathComponent("auth/key")

    static func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        model: String,
        language: String?,
        customVocabulary: [String],
        timeout: TimeInterval = 60
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }

        var payload: [String: Any] = [
            "model": model,
            "input_audio": [
                "data": audioData.base64EncodedString(),
                "format": audioFormat(for: fileName),
            ],
            "response_format": "json",
            "temperature": 0,
        ]
        if let language, !language.isEmpty {
            payload["language"] = language
        }
        if let phraseList = phraseListOptions(for: customVocabulary) {
            payload["provider"] = ["options": ["azure": ["phraseList": phraseList]]]
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw CloudTranscriptionError.dataEncodingError
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Ephemeral session per request, for the same HTTP/3 upload reason as
        // OpenAICompatibleTranscriptionService.
        let session = URLSession(configuration: .ephemeral)
        session.configuration.timeoutIntervalForRequest = timeout
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch {
            throw CloudTranscriptionError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw CloudTranscriptionError.invalidAPIKey
            }
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: httpResponse.statusCode,
                message: errorMessage(from: data) ?? "No error message"
            )
        }

        guard let text = try? JSONDecoder().decode(TranscriptionResponse.self, from: data).text else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        return text
    }

    static func verifyAPIKey(_ key: String, timeout: TimeInterval = 10) async -> (isValid: Bool, errorMessage: String?) {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, String(localized: "API key is missing or empty."))
        }

        var request = URLRequest(url: keyVerificationURL)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, String(localized: "No HTTP response received."))
            }
            if (200...299).contains(httpResponse.statusCode) {
                return (true, nil)
            }
            return (false, errorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// OpenRouter identifies the container by name, not by MIME type.
    static func audioFormat(for fileName: String) -> String {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        return fileExtension.isEmpty ? "wav" : fileExtension
    }

    /// MAI-Transcribe 2 biases recognition toward a phrase list, which is where
    /// VoiceInk's custom dictionary belongs.
    static func phraseListOptions(for customVocabulary: [String]) -> [String: Any]? {
        let phrases = customVocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !phrases.isEmpty else { return nil }
        return ["phrases": phrases]
    }

    private static func errorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return decoded.error.message
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private struct ErrorResponse: Decodable {
        struct Payload: Decodable {
            let message: String
        }
        let error: Payload
    }
}
