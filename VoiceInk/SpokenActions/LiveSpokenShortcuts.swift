import Foundation

/// Streaming transcripts are cumulative. Remember consumed phrase occurrences so
/// repeated previews do not post the same key again.
struct LiveSpokenShortcuts {
    private var consumed: [String: Set<Int>] = [:]

    mutating func consume(in text: String, actions: [SpokenPhraseAction]) -> Shortcut? {
        let candidates = actions.filter {
            $0.isEnabled && $0.operation == .keyboardShortcut
                && $0.endsDictationAutomatically && $0.startsNewDictationAutomatically
        }.sorted {
            SpokenPhraseMatcher.words(in: $0.phrase).count > SpokenPhraseMatcher.words(in: $1.phrase).count
        }
        for action in candidates {
            let phrase = SpokenPhraseMatcher.normalized(action.phrase)
            let matches = ranges(of: phrase, in: text)
            guard let last = matches.last,
                last.upperBound == SpokenPhraseMatcher.words(in: text).last?.range.upperBound,
                !consumed[phrase, default: []].contains(matches.count)
            else { continue }
            consumed[phrase, default: []].insert(matches.count)
            return action.shortcut
        }
        return nil
    }

    func removingConsumedPhrases(from text: String) -> String {
        let removals = consumed.flatMap { phrase, occurrences in
            ranges(of: phrase, in: text).enumerated().compactMap { index, range in
                occurrences.contains(index + 1) ? range : nil
            }
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in removals {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var result = text
        for range in merged.reversed() {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ranges(of phrase: String, in text: String) -> [Range<String.Index>] {
        let words = SpokenPhraseMatcher.words(in: text)
        let phraseWords = SpokenPhraseMatcher.words(in: phrase).map(\.value)
        guard !phraseWords.isEmpty, words.count >= phraseWords.count else { return [] }
        var matches: [Range<String.Index>] = []
        var index = 0
        while index + phraseWords.count <= words.count {
            let end = index + phraseWords.count
            if words[index..<end].map(\.value) == phraseWords {
                matches.append(words[index].range.lowerBound..<words[end - 1].range.upperBound)
                index = end
            } else {
                index += 1
            }
        }
        return matches
    }
}
