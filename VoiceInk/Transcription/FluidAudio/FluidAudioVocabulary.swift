import FluidAudio
import Foundation

struct FluidAudioVocabulary {
    let context: CustomVocabularyContext
    let ctcModels: CtcModels

    static func load(words: [String]) async throws -> FluidAudioVocabulary? {
        guard !words.isEmpty else { return nil }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-vocabulary-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let terms = words.map { ["text": $0, "weight": 10.0] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["terms": terms])
        try data.write(to: fileURL, options: .atomic)
        let loaded = try await CustomVocabularyContext.loadWithCtcTokens(from: fileURL.path)
        guard !loaded.vocab.terms.isEmpty else { return nil }
        return FluidAudioVocabulary(context: loaded.vocab, ctcModels: loaded.models)
    }
}
