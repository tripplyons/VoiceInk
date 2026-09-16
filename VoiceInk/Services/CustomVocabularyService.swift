import Foundation
import SwiftData
import SwiftUI

class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    func getCustomVocabulary(from context: ModelContext) -> String {
        let words = getCustomVocabularyWords(from: context)
        guard !words.isEmpty else { return "" }

        return "Important Vocabulary: \(words.joined(separator: ", "))"
    }

    func getCustomVocabularyWords(from context: ModelContext) -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])
        guard let items = try? context.fetch(descriptor) else { return [] }

        var seen = Set<String>()
        return items.compactMap { item in
            let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }
}
