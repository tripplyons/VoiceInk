import Foundation

struct SpokenSubmitCommand: Equatable {
    let textToPaste: String

    static func match(text: String, phrase: String) -> SpokenSubmitCommand? {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return nil }

        let trailingCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let candidate = text.trimmingCharacters(in: trailingCharacters)
        guard let phraseRange = candidate.range(
            of: phrase,
            options: [.caseInsensitive, .anchored, .backwards]
        ) else {
            return nil
        }

        if phraseRange.lowerBound != candidate.startIndex {
            let precedingIndex = candidate.index(before: phraseRange.lowerBound)
            guard candidate[precedingIndex].isWhitespace else { return nil }
        }

        let textToPaste = String(candidate[..<phraseRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SpokenSubmitCommand(textToPaste: textToPaste)
    }
}
