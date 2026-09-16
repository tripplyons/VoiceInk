import Foundation
import Testing
@testable import VoiceInk

struct LiveSpokenShortcutsTests {
    private func action(_ phrase: String) -> SpokenPhraseAction {
        SpokenPhraseAction(
            phrase: phrase,
            shortcut: .key(keyCode: 36, modifierFlags: []),
            endsDictationAutomatically: true,
            startsNewDictationAutomatically: true
        )
    }

    @Test func consumesOnlyThePhraseAndDoesNotRepeatTheKey() {
        var state = LiveSpokenShortcuts()
        let command = action("press return")
        #expect(state.consume(in: "my draft press return", actions: [command]) == command.shortcut)
        #expect(state.removingConsumedPhrases(from: "my draft press return") == "my draft")
        #expect(state.consume(in: "my draft press return", actions: [command]) == nil)
        #expect(state.removingConsumedPhrases(from: "my draft press return more") == "my draft  more")
    }

    @Test func supportsCommandOnlyAndRepeatedCommands() {
        var state = LiveSpokenShortcuts()
        let command = action("press return")
        #expect(state.consume(in: "press return", actions: [command]) != nil)
        #expect(state.removingConsumedPhrases(from: "press return").isEmpty)
        #expect(state.consume(in: "press return press return", actions: [command]) != nil)
        #expect(state.consume(in: "press return press return", actions: [command]) == nil)
        #expect(state.removingConsumedPhrases(from: "press return press return").isEmpty)
    }

    @Test func doesNotConsumeDisabledOrNonContinuingActions() {
        var state = LiveSpokenShortcuts()
        var command = action("press return")
        command.isEnabled = false
        #expect(state.consume(in: "press return", actions: [command]) == nil)
        command.isEnabled = true
        command.startsNewDictationAutomatically = false
        #expect(state.consume(in: "press return", actions: [command]) == nil)
        command.startsNewDictationAutomatically = true
        command.operation = .submitStackAndKeyboardShortcut
        #expect(state.consume(in: "press return", actions: [command]) == nil)
    }

    @Test func preservesEarlierUnmatchedMentionOfThePhrase() {
        var state = LiveSpokenShortcuts()
        let command = action("press return")
        let text = "say press return later then press return"
        #expect(state.consume(in: text, actions: [command]) != nil)
        #expect(state.removingConsumedPhrases(from: text) == "say press return later then")
    }

    @Test func finalTranscriptRetainsRevisedDictation() {
        var state = LiveSpokenShortcuts()
        let command = action("press return")
        _ = state.consume(in: "rough draft press return", actions: [command])
        #expect(state.removingConsumedPhrases(from: "Revised draft press return") == "Revised draft")
    }

    @Test func exitIsExplicitAndDoesNotMapToSubmit() {
        var command = action("stop listening")
        command.operation = .exitContinuousMode
        command.endsDictationAutomatically = false
        #expect(ContinuousVoiceCommandMatcher.match(in: "stop listening", actions: [command])?.command == .exitContinuousMode)
        #expect(ContinuousVoiceCommandMatcher.match(in: "stop listening", actions: []) == nil)
        command.isEnabled = false
        #expect(ContinuousVoiceCommandMatcher.match(in: "stop listening", actions: [command]) == nil)
    }
}
