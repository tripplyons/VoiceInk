import Foundation

/// Splits cumulative previews at spoken commands without ending the audio session.
/// Anchor to the last consumed command rather than a character offset: providers
/// can revise the dictation preceding that command in later previews.
struct ContinuousCommandStream {
    private var boundary: (phrase: [String], occurrence: Int)?

    mutating func consume(in text: String, actions: [SpokenPhraseAction]) -> [ContinuousVoiceCommandMatch] {
        let words = SpokenPhraseMatcher.words(in: text)
        guard let start = remainingWordIndex(in: words.map(\.value)) else { return [] }
        let candidates = actions.filter(\.canRun).map { action in
            (action: action, words: SpokenPhraseMatcher.words(in: action.phrase).map(\.value))
        }.filter { !$0.words.isEmpty }.sorted { $0.words.count > $1.words.count }
        var results: [ContinuousVoiceCommandMatch] = []
        var segmentStart = start
        var index = start
        while index < words.count {
            guard let candidate = candidates.first(where: {
                index + $0.words.count <= words.count
                    && words[index..<(index + $0.words.count)].map(\.value) == $0.words
            }) else {
                index += 1
                continue
            }
            let prefix = String(text[words[segmentStart].range.lowerBound..<words[index].range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let end = index + candidate.words.count
            let occurrence = matchingEnds(of: candidate.words, in: Array(words[..<end].map(\.value))).count
            boundary = (candidate.words, occurrence)
            results.append(ContinuousVoiceCommandMatch(
                command: candidate.action.continuousCommand, remainingText: prefix
            ))
            index = end
            segmentStart = end
            if candidate.action.operation == .exitContinuousMode { break }
        }
        return results
    }

    func remainingText(in text: String) -> String {
        guard boundary != nil else { return text }
        let words = SpokenPhraseMatcher.words(in: text)
        guard let start = remainingWordIndex(in: words.map(\.value)), start < words.count else { return "" }
        return String(text[words[start].range.lowerBound...])
    }

    private func remainingWordIndex(in words: [String]) -> Int? {
        guard let boundary else { return 0 }
        let ends = matchingEnds(of: boundary.phrase, in: words)
        guard ends.count >= boundary.occurrence else { return nil }
        return ends[boundary.occurrence - 1]
    }

    private func matchingEnds(of phrase: [String], in words: [String]) -> [Int] {
        var ends: [Int] = []
        var index = 0
        while index + phrase.count <= words.count {
            if Array(words[index..<(index + phrase.count)]) == phrase {
                index += phrase.count
                ends.append(index)
            } else {
                index += 1
            }
        }
        return ends
    }
}

extension SpokenPhraseAction {
    var continuousCommand: ContinuousVoiceCommand {
        switch operation {
        case .keyboardShortcut: return .runShortcut(shortcut)
        case .insertText: return .insertText(savedText)
        case .pushStack: return .pushStack
        case .submitStack: return .submitStack
        case .resetStack: return .resetStack
        case .exitContinuousMode: return .exitContinuousMode
        case .submitStackAndKeyboardShortcut: return .submitStackAndRunShortcut(shortcut)
        }
    }
}
