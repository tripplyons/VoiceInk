import Foundation
import Testing
@testable import VoiceInk

struct SavedTextActionTests {
    private func textAction(_ text: String = "npm test") -> SpokenPhraseAction {
        SpokenPhraseAction(
            phrase: "run tests", shortcut: .key(keyCode: 36, modifierFlags: []),
            endsDictationAutomatically: true, operation: .insertText, savedText: text
        )
    }

    @Test func savedTextAndExistingCommandsStayInSpokenOrder() {
        var stream = ContinuousCommandStream()
        let insert = textAction()
        let submit = SpokenPhraseAction(
            phrase: "press return", shortcut: .key(keyCode: 36, modifierFlags: []),
            endsDictationAutomatically: true, operation: .submitStackAndKeyboardShortcut
        )
        let navigate = SpokenPhraseAction(
            phrase: "top right", shortcut: .key(keyCode: 34, modifierFlags: .command)
        )
        let text = "run tests press return top right"
        let actions = [insert, submit, navigate]
        #expect(stream.consume(in: text, actions: actions).map(\.command) == [
            .insertText("npm test"), .submitStackAndRunShortcut(submit.shortcut), .runShortcut(navigate.shortcut),
        ])
        #expect(stream.remainingText(in: text).isEmpty)
        #expect(stream.consume(in: text, actions: actions).isEmpty)
    }

    @Test func savedTextIsLiteralAndDoesNotBecomeAnotherSpokenCommand() {
        var stream = ContinuousCommandStream()
        let saved = "  echo 'press return'\n\tprintf 'done'  "
        let matches = stream.consume(in: "keep this run tests more dictation", actions: [textAction(saved)])
        #expect(matches == [ContinuousVoiceCommandMatch(command: .insertText(saved), remainingText: "keep this")])
        #expect(stream.remainingText(in: "keep this run tests more dictation") == "more dictation")
        #expect(SavedTextInsertion.text(saved) == saved)
        #expect(SavedTextInsertion.text(saved, after: " hello ") == "hello " + saved)
        #expect(ContinuousVoiceCommand.insertText(saved).logName == "insertText")
    }

    @Test func normalDictationRecognizesTheSavedTextAction() {
        let action = textAction()
        #expect(SpokenPhraseMatcher.exactMatch(in: "Run tests!", actions: [action]) == action)
        #expect(SpokenPhraseMatcher.suffixMatch(in: "hello run tests", actions: [action]) ==
            SpokenPhraseMatch(action: action, remainingText: "hello"))
        var detector = SpokenPhraseTriggerDetector()
        #expect(detector.matchPreview("hello run tests", actions: [action])?.action == action)
        #expect(detector.matchPreview("hello run tests", actions: [action]) == nil)
        detector.reset()
        #expect(detector.matchPreview("run tests", actions: [action])?.action == action)
    }

    @Test func emptyAndDisabledTextActionsDoNotConsumeDictation() {
        var stream = ContinuousCommandStream()
        var disabled = textAction()
        disabled.isEnabled = false
        for action in [textAction(""), textAction(" \n\t"), disabled] {
            #expect(stream.consume(in: "run tests", actions: [action]).isEmpty)
            #expect(SpokenPhraseMatcher.exactMatch(in: "run tests", actions: [action]) == nil)
            #expect(stream.remainingText(in: "run tests") == "run tests")
        }
    }

    @Test func savedTextSurvivesCoding() throws {
        let action = textAction("echo 'hello 👋'\n  npm test\n")
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(SpokenPhraseAction.self, from: data) == action)
    }

    @Test func existingActionsDecodeWithoutSavedText() throws {
        var action = textAction()
        action.operation = .keyboardShortcut
        action.savedText = ""
        let data = try JSONEncoder().encode(action)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "savedText")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(SpokenPhraseAction.self, from: legacy) == action)
    }

    @Test @MainActor func savedTextSurvivesStoreReload() {
        let suite = "SavedTextActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let action = textAction()
        SpokenPhraseActionStore(defaults: defaults).add(action)
        #expect(SpokenPhraseActionStore(defaults: defaults).actions == [action])
    }
}
