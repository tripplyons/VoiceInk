import Foundation
import Testing
@testable import VoiceInk

struct ContinuousCommandStreamTests {
    // Match the installed configuration: Return submits; window shortcuts do not
    // end dictation. Continuous mode must keep listening regardless of restart.
    private let pressReturn = SpokenPhraseAction(
        phrase: "press return", shortcut: .key(keyCode: 36, modifierFlags: []),
        endsDictationAutomatically: true, startsNewDictationAutomatically: false,
        operation: .submitStackAndKeyboardShortcut
    )
    private let topRight = SpokenPhraseAction(
        phrase: "top right", shortcut: .key(keyCode: 34, modifierFlags: .command),
        endsDictationAutomatically: false, startsNewDictationAutomatically: true
    )

    @Test func commandsInsideOnePreviewExecuteInSpokenOrder() {
        var stream = ContinuousCommandStream()
        let text = "hello press return top right"
        let matches = stream.consume(in: text, actions: [topRight, pressReturn])
        #expect(matches == [
            ContinuousVoiceCommandMatch(command: .submitStackAndRunShortcut(pressReturn.shortcut), remainingText: "hello"),
            ContinuousVoiceCommandMatch(command: .runShortcut(topRight.shortcut), remainingText: ""),
        ])
        #expect(stream.remainingText(in: text).isEmpty)
        #expect(stream.consume(in: text, actions: [pressReturn, topRight]).isEmpty)
    }

    @Test func incrementalPreviewsAndFinalDoNotReplayCommandsOrSubmittedText() {
        var stream = ContinuousCommandStream()
        let actions = [pressReturn, topRight]
        #expect(stream.consume(in: "hello press", actions: actions).isEmpty)
        #expect(stream.consume(in: "hello press return", actions: actions).count == 1)
        #expect(stream.consume(in: "hello press return top", actions: actions).isEmpty)
        #expect(stream.remainingText(in: "hello press return top") == "top")
        let matches = stream.consume(in: "hello press return top right keep talking", actions: actions)
        #expect(matches.map(\.command) == [.runShortcut(topRight.shortcut)])
        #expect(stream.remainingText(in: "Hello, press return. Top right! Keep talking.") == "Keep talking.")
        #expect(stream.consume(in: "Hello, press return. Top right! Keep talking.", actions: actions).isEmpty)
    }

    @Test func revisedPrefixDoesNotShiftTheConsumedBoundary() {
        var stream = ContinuousCommandStream()
        _ = stream.consume(in: "rough words press return", actions: [pressReturn])
        let revised = "A much longer revised sentence press return more text"
        #expect(stream.consume(in: revised, actions: [pressReturn]).isEmpty)
        #expect(stream.remainingText(in: revised) == "more text")
        #expect(stream.remainingText(in: "temporary shorter preview").isEmpty)
        #expect(stream.consume(in: "temporary shorter preview", actions: [pressReturn]).isEmpty)
    }

    @Test func repeatedCommandsKeepTheirOwnPrecedingText() {
        var stream = ContinuousCommandStream()
        let text = "one press return two press return three"
        let matches = stream.consume(in: text, actions: [pressReturn])
        #expect(matches.map(\.remainingText) == ["one", "two"])
        #expect(stream.remainingText(in: text) == "three")
        #expect(stream.consume(in: text, actions: [pressReturn]).isEmpty)
        #expect(stream.consume(in: text + " press return", actions: [pressReturn]).map(\.remainingText) == ["three"])
    }

    @Test func disabledEmptyAndPartialWordPhrasesDoNotExecute() {
        var stream = ContinuousCommandStream()
        var disabled = pressReturn
        disabled.isEnabled = false
        var empty = topRight
        empty.phrase = "..."
        let text = "hello press return top rightmost"
        #expect(stream.consume(in: text, actions: [disabled, empty, topRight]).isEmpty)
        #expect(stream.remainingText(in: text) == text)
    }

    @Test func longestPhraseWinsAtTheSamePositionAndExitStopsTheBatch() {
        var stream = ContinuousCommandStream()
        var short = topRight
        short.phrase = "top"
        var exit = topRight
        exit.phrase = "stop listening"
        exit.operation = .exitContinuousMode
        let matches = stream.consume(
            in: "top right stop listening press return", actions: [short, topRight, exit, pressReturn]
        )
        #expect(matches.map(\.command) == [.runShortcut(topRight.shortcut), .exitContinuousMode])
    }

    @Test @MainActor func deliveryFinishesBeforeTheNextShortcutRuns() async {
        let queue = ContinuousCommandQueue()
        var events: [String] = []
        var releasePaste: CheckedContinuation<Void, Never>?
        queue.enqueue {
            events.append("paste started")
            await withCheckedContinuation { releasePaste = $0 }
            events.append("paste finished")
            events.append("return")
        }
        queue.enqueue { events.append("top right") }
        while releasePaste == nil { await Task.yield() }
        #expect(events == ["paste started"])
        releasePaste?.resume()
        await queue.waitUntilFinished()
        #expect(events == ["paste started", "paste finished", "return", "top right"])
    }

    @Test @MainActor func canceledSessionDoesNotExecuteQueuedShortcuts() async {
        let queue = ContinuousCommandQueue()
        var releasePaste: CheckedContinuation<Void, Never>?
        var events: [String] = []
        queue.enqueue { await withCheckedContinuation { releasePaste = $0 } }
        queue.enqueue { events.append("old top right") }
        while releasePaste == nil { await Task.yield() }
        queue.cancel()
        queue.enqueue { events.append("new session") }
        releasePaste?.resume()
        await queue.waitUntilFinished()
        #expect(events == ["new session"])
    }
}
