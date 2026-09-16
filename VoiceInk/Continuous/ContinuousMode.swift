import Foundation

/// Operations that a spoken action can perform while continuous mode is listening.
enum ContinuousVoiceCommand: Equatable {
    case pushStack
    case submitStack
    case resetStack
    case runShortcut(Shortcut)
    case submitStackAndRunShortcut(Shortcut)
}

struct ContinuousVoiceCommandMatch: Equatable {
    let command: ContinuousVoiceCommand
    let remainingText: String
}

/// Keeps the text collected between spoken stack commands.
struct ContinuousTextStack: Equatable {
    private(set) var entries: [String] = []

    var text: String {
        entries.joined(separator: " ")
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    mutating func push(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(trimmed)
    }

    mutating func reset() {
        entries.removeAll()
    }
}

enum ContinuousVoiceCommandMatcher {
    static func match(
        in text: String,
        actions: [SpokenPhraseAction]
    ) -> ContinuousVoiceCommandMatch? {
        let continuousActions = actions
            .enumerated()
            .filter {
                $0.element.isEnabled
                    && ($0.element.operation != .keyboardShortcut || $0.element.endsDictationAutomatically)
            }
            .sorted { lhs, rhs in
                let lhsWords = SpokenPhraseMatcher.normalized(lhs.element.phrase).split(separator: " ").count
                let rhsWords = SpokenPhraseMatcher.normalized(rhs.element.phrase).split(separator: " ").count
                if lhsWords != rhsWords {
                    return lhsWords > rhsWords
                }

                let lhsCharacters = SpokenPhraseMatcher.normalized(lhs.element.phrase).count
                let rhsCharacters = SpokenPhraseMatcher.normalized(rhs.element.phrase).count
                if lhsCharacters != rhsCharacters {
                    return lhsCharacters > rhsCharacters
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)

        for action in continuousActions {
            guard let remainingText = SpokenPhraseMatcher.suffixRemainingText(
                in: text,
                matching: action.phrase,
                allowingExact: true
            ) else {
                continue
            }

            let command: ContinuousVoiceCommand
            switch action.operation {
            case .keyboardShortcut:
                command = .runShortcut(action.shortcut)
            case .pushStack:
                command = .pushStack
            case .submitStack:
                command = .submitStack
            case .resetStack:
                command = .resetStack
            case .submitStackAndKeyboardShortcut:
                command = .submitStackAndRunShortcut(action.shortcut)
            }

            return ContinuousVoiceCommandMatch(command: command, remainingText: remainingText)
        }

        return nil
    }
}
