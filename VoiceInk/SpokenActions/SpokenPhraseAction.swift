import AppKit
import Combine
import Foundation

struct SpokenPhraseAction: Codable, Equatable, Identifiable {
  var id = UUID()
  var phrase: String
  var shortcut: Shortcut
  var isEnabled = true
  var endsDictationAutomatically = false
}

struct SpokenPhraseMatch: Equatable {
  let action: SpokenPhraseAction
  let remainingText: String
}

enum SpokenPhraseMatcher {
  static func normalized(_ text: String) -> String {
    words(in: text).map(\.value).joined(separator: " ")
  }

  static func exactMatch(in text: String, actions: [SpokenPhraseAction]) -> SpokenPhraseAction? {
    let normalizedText = normalized(text)
    guard !normalizedText.isEmpty else { return nil }
    return enabledActions(actions).first { normalized($0.phrase) == normalizedText }
  }

  static func suffixMatch(in text: String, actions: [SpokenPhraseAction]) -> SpokenPhraseMatch? {
    let textWords = words(in: text)
    guard !textWords.isEmpty else { return nil }

    for action in enabledActions(actions).filter(\.endsDictationAutomatically) {
      let phraseWords = words(in: action.phrase)
      guard !phraseWords.isEmpty, phraseWords.count <= textWords.count else { continue }
      guard
        zip(textWords.suffix(phraseWords.count), phraseWords).allSatisfy({ pair in
          pair.0.value == pair.1.value
        })
      else {
        continue
      }

      let start = textWords[textWords.count - phraseWords.count].range.lowerBound
      let remaining = text[..<start].trimmingCharacters(
        in: .whitespacesAndNewlines.union(.punctuationCharacters))
      return SpokenPhraseMatch(action: action, remainingText: remaining)
    }

    return nil
  }

  static func removingSuffix(for actionID: UUID, from text: String, actions: [SpokenPhraseAction])
    -> SpokenPhraseMatch?
  {
    guard let action = actions.first(where: { $0.id == actionID && $0.isEnabled }) else {
      return nil
    }
    return suffixMatch(in: text, actions: [action])
  }

  private static func enabledActions(_ actions: [SpokenPhraseAction]) -> [SpokenPhraseAction] {
    actions.filter { $0.isEnabled && !normalized($0.phrase).isEmpty }
  }

  private static func words(in text: String) -> [(value: String, range: Range<String.Index>)] {
    var result: [(String, Range<String.Index>)] = []
    var start: String.Index?
    var index = text.startIndex

    func appendWord(endingAt end: String.Index) {
      guard let start else { return }
      let value = text[start..<end].folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: .current
      )
      .lowercased()
      result.append((value, start..<end))
    }

    while index < text.endIndex {
      if text[index].isLetter || text[index].isNumber {
        start = start ?? index
      } else if start != nil {
        appendWord(endingAt: index)
        start = nil
      }
      index = text.index(after: index)
    }
    appendWord(endingAt: text.endIndex)
    return result
  }
}

struct SpokenPhraseTriggerDetector {
  private(set) var triggeredActionID: UUID?

  mutating func matchPreview(_ text: String, actions: [SpokenPhraseAction]) -> SpokenPhraseMatch? {
    guard triggeredActionID == nil,
      let match = SpokenPhraseMatcher.suffixMatch(in: text, actions: actions)
    else { return nil }
    triggeredActionID = match.action.id
    return match
  }

  mutating func reset() {
    triggeredActionID = nil
  }
}

@MainActor
final class SpokenPhraseActionStore: ObservableObject {
  static let shared = SpokenPhraseActionStore()
  static let defaultsKey = "spokenPhraseActions"

  @Published private(set) var actions: [SpokenPhraseAction] = []
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    load()
  }

  func add(_ action: SpokenPhraseAction) {
    actions.append(action)
    save()
  }

  func update(_ action: SpokenPhraseAction) {
    guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
    actions[index] = action
    save()
  }

  func remove(id: UUID) {
    actions.removeAll { $0.id == id }
    save()
  }

  func replaceAll(with newActions: [SpokenPhraseAction]) {
    actions = newActions
    save()
  }

  private func load() {
    guard let data = defaults.data(forKey: Self.defaultsKey),
      let decoded = try? JSONDecoder().decode([SpokenPhraseAction].self, from: data)
    else { return }
    actions = decoded
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(actions) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }
}

enum SpokenShortcutRunner {
  @MainActor
  @discardableResult
  static func run(_ shortcut: Shortcut) -> Bool {
    guard AXIsProcessTrusted() else {
      NotificationManager.shared.showNotification(
        title: "Accessibility permission is required to run spoken actions.",
        type: .error
      )
      return false
    }

    guard shortcut.kind == .key,
      let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: true),
      let up = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: false)
    else {
      NotificationManager.shared.showNotification(
        title: "The spoken action has an invalid keyboard shortcut.",
        type: .error
      )
      return false
    }

    down.flags = CGEventFlags(rawValue: UInt64(shortcut.modifierFlags.rawValue))
    up.flags = down.flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }
}
