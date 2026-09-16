import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let spokenShortcut: Shortcut?
        let startsNewDictationAfterSpokenShortcut: Bool
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async -> Bool {
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return false
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return false
        }

        if let shortcut = request.spokenShortcut {
            if let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                return await paste(
                    text,
                    output: request.output,
                    spokenShortcut: shortcut,
                    startsNewDictationAfterSpokenShortcut: request.startsNewDictationAfterSpokenShortcut,
                    actions: actions
                )
            } else {
                SoundManager.shared.playStopSound()
                await actions.dismiss()
                let didRunShortcut = SpokenShortcutRunner.run(shortcut)
                return didRunShortcut && request.startsNewDictationAfterSpokenShortcut
            }
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return false
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return false
        }

        if let text = request.text {
            return await paste(
                text,
                output: request.output,
                spokenShortcut: request.spokenShortcut,
                startsNewDictationAfterSpokenShortcut: false,
                actions: actions
            )
        } else {
            await actions.dismiss()
            return false
        }
    }

    /// Delivers the text accumulated by continuous mode without closing its recorder panel.
    @discardableResult
    func deliverStackText(_ text: String, output: OutputRuntimeConfiguration) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }

        switch output.outputMode {
        case .paste:
            let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
            let pastedText = trimmedText + (appendSpace ? " " : "")
            let pasteResult = await CursorPaster.pasteAtCursorAndWaitUntilPosted(pastedText)
            guard pasteResult.didPostPasteCommand else { return false }

            if output.autoSendKey.isEnabled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                CursorPaster.performAutoSend(output.autoSendKey)
            }
            return true

        case .customCommand:
            guard let command = output.customCommand?.trimmedCommand else {
                notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
                return false
            }
            return await runCustomCommand(command: command, commandText: trimmedText)

        case .respond:
            NotificationManager.shared.showNotification(
                title: String(localized: "Continuous stack submission is not supported for Respond output."),
                type: .warning
            )
            return false
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let commandText = text
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        Task {
            await runCustomCommand(command: command, commandText: commandText)
        }
    }

    private func runCustomCommand(command: String, commandText: String) async -> Bool {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }
            return true
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
            return false
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(
        _ text: String,
        output: OutputRuntimeConfiguration,
        spokenShortcut: Shortcut?,
        startsNewDictationAfterSpokenShortcut: Bool,
        actions: Actions
    ) async -> Bool {
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace") && spokenShortcut == nil
        let pastedText = text + (appendSpace ? " " : "")
        let autoSendKey = output.outputMode == .paste ? output.autoSendKey : .none

        SoundManager.shared.playStopSound()
        await actions.dismiss()

        let pasteTask = CursorPaster.startPasteAtCursor(pastedText)

        if let spokenShortcut, startsNewDictationAfterSpokenShortcut {
            let pasteResult = await pasteTask.value
            guard pasteResult.didPostPasteCommand else { return false }

            try? await Task.sleep(nanoseconds: 500_000_000)
            return SpokenShortcutRunner.run(spokenShortcut)
        }

        Task { @MainActor in
            let pasteResult = await pasteTask.value
            guard pasteResult.didPostPasteCommand else { return }

            if let spokenShortcut {
                try? await Task.sleep(nanoseconds: 500_000_000)
                SpokenShortcutRunner.run(spokenShortcut)
            } else if autoSendKey.isEnabled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                CursorPaster.performAutoSend(autoSendKey)
            }
        }
        return false
    }
}
