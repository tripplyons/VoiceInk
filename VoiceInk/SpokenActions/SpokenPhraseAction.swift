import AppKit
import Combine
import Foundation

struct SpokenPhraseAction: Codable, Equatable, Identifiable {
  enum Operation: String, Codable, CaseIterable {
    case keyboardShortcut
    case insertText
    case pushStack
    case submitStack
    case resetStack
    case exitContinuousMode
    case submitStackAndKeyboardShortcut

    var displayName: String {
      switch self {
      case .keyboardShortcut:
        return String(localized: "Run Keyboard Shortcut")
      case .insertText:
        return String(localized: "Insert Saved Text")
      case .pushStack:
        return String(localized: "Push Text to Stack")
      case .submitStack:
        return String(localized: "Submit Stack")
      case .resetStack:
        return String(localized: "Reset Stack")
      case .exitContinuousMode:
        return String(localized: "Exit Continuous Mode")
      case .submitStackAndKeyboardShortcut:
        return String(localized: "Submit Stack + Keyboard Shortcut")
      }
    }

    var usesKeyboardShortcut: Bool {
      self == .keyboardShortcut || self == .submitStackAndKeyboardShortcut
    }
  }

  var id = UUID()
  var phrase: String
  var shortcut: Shortcut
  var isEnabled = true
  var endsDictationAutomatically = false
  var startsNewDictationAutomatically = false
  var operation: Operation = .keyboardShortcut
  var savedText = ""

  var canRun: Bool {
    isEnabled && (operation != .insertText || !savedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}

extension SpokenPhraseAction {
  private enum CodingKeys: String, CodingKey {
    case id
    case phrase
    case shortcut
    case isEnabled
    case endsDictationAutomatically
    case startsNewDictationAutomatically
    case operation
    case savedText
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    phrase = try container.decode(String.self, forKey: .phrase)
    shortcut = try container.decode(Shortcut.self, forKey: .shortcut)
    isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    endsDictationAutomatically = try container.decode(Bool.self, forKey: .endsDictationAutomatically)
    startsNewDictationAutomatically =
      try container.decodeIfPresent(Bool.self, forKey: .startsNewDictationAutomatically) ?? false
    operation = (try? container.decodeIfPresent(Operation.self, forKey: .operation)) ?? .keyboardShortcut
    savedText = try container.decodeIfPresent(String.self, forKey: .savedText) ?? ""
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(phrase, forKey: .phrase)
    try container.encode(shortcut, forKey: .shortcut)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(endsDictationAutomatically, forKey: .endsDictationAutomatically)
    try container.encode(startsNewDictationAutomatically, forKey: .startsNewDictationAutomatically)
    try container.encode(operation, forKey: .operation)
    try container.encode(savedText, forKey: .savedText)
  }
}

enum SavedTextInsertion {
  static func text(_ savedText: String, after dictation: String = "") -> String {
    let prefix = dictation.trimmingCharacters(in: .whitespacesAndNewlines)
    return prefix.isEmpty ? savedText : prefix + " " + savedText
  }
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
    for action in enabledActions(actions).filter(\.endsDictationAutomatically) {
      guard let remainingText = suffixRemainingText(
        in: text,
        matching: action.phrase,
        allowingExact: action.operation == .insertText
      ) else {
        continue
      }
      return SpokenPhraseMatch(action: action, remainingText: remainingText)
    }

    return nil
  }

  /// Returns the text before a phrase at the end of a transcription.
  /// Exact matches are optional because normal dictation requires some text before an action.
  static func suffixRemainingText(
    in text: String,
    matching phrase: String,
    allowingExact: Bool
  ) -> String? {
    let textWords = words(in: text)
    let phraseWords = words(in: phrase)
    guard !textWords.isEmpty,
      !phraseWords.isEmpty,
      phraseWords.count <= textWords.count,
      allowingExact || phraseWords.count < textWords.count,
      zip(textWords.suffix(phraseWords.count), phraseWords).allSatisfy({ pair in
        pair.0.value == pair.1.value
      })
    else {
      return nil
    }

    let start = textWords[textWords.count - phraseWords.count].range.lowerBound
    return text[..<start].trimmingCharacters(
      in: .whitespacesAndNewlines.union(.punctuationCharacters))
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
    actions.filter { $0.canRun && !normalized($0.phrase).isEmpty }
  }

  static func words(in text: String) -> [(value: String, range: Range<String.Index>)] {
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
    if let data = defaults.data(forKey: Self.defaultsKey),
      let decoded = try? JSONDecoder().decode([SpokenPhraseAction].self, from: data)
    {
      actions = decoded
    }

    migrateLegacySpokenSubmitIfNeeded()
  }

  private func migrateLegacySpokenSubmitIfNeeded() {
    let migrationKey = "spokenSubmitMigratedToSpokenAction"
    guard !defaults.bool(forKey: migrationKey),
      defaults.bool(forKey: "spokenSubmitEnabled"),
      let legacyPhrase = defaults.string(forKey: "spokenSubmitPhrase")
    else {
      return
    }

    let phrase = legacyPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !SpokenPhraseMatcher.normalized(phrase).isEmpty else { return }

    let returnShortcut = Shortcut.key(keyCode: 36, modifierFlags: [])
    if let index = actions.firstIndex(where: {
      SpokenPhraseMatcher.normalized($0.phrase) == SpokenPhraseMatcher.normalized(phrase)
    }) {
      actions[index].shortcut = returnShortcut
      actions[index].endsDictationAutomatically = true
      actions[index].operation = .submitStackAndKeyboardShortcut
    } else {
      actions.append(
        SpokenPhraseAction(
          phrase: phrase,
          shortcut: returnShortcut,
          endsDictationAutomatically: true,
          operation: .submitStackAndKeyboardShortcut
        )
      )
    }

    defaults.set(true, forKey: migrationKey)
    save()
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
