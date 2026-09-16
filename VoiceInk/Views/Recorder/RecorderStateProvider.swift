import Foundation

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    var isContinuousModeEnabled: Bool { get }
    var continuousStackText: String { get }
    func replaceContinuousStack(with text: String)
}

extension RecorderStateProvider {
    var continuousTranscriptText: String {
        let stack = continuousStackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stack.isEmpty else { return partial }
        guard !partial.isEmpty else { return stack }
        return "\(stack) \(partial)"
    }
}
