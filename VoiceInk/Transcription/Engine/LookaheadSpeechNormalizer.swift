import Foundation

/// Configurable fixed-frame lookahead. Chunk boundaries do not change analysis or output.
/// The same measured gain serves every channel; finish emits an unpadded tail.
final class LookaheadSpeechNormalizer {
    private let channelCount: Int
    private let frameSize: Int
    private let buffers: [UnsafeMutablePointer<Float>]
    private var probabilities: [Float]
    private var frameCount = 0
    private var frameHasConfidence = false
    private var finished = false
    private var leveler: StreamingSpeechLeveler
    private var output: [[Float]]
    private(set) var outputSpeechProbabilities: [Float] = []

    init(sampleRate: Double, strength: Float, channelCount: Int = 1,
         timing: NormalizationSettings.Timing = .init()) {
        precondition(channelCount > 0)
        self.channelCount = channelCount
        let size = max(1, Int(max(sampleRate, 1) * timing.lookaheadSeconds))
        frameSize = size
        buffers = (0..<channelCount).map { _ in .allocate(capacity: size) }
        probabilities = [Float](repeating: 1, count: size)
        leveler = StreamingSpeechLeveler(sampleRate: sampleRate, strength: strength, timing: timing)
        output = [[Float]](repeating: [], count: channelCount)
    }

    deinit { for buffer in buffers { buffer.deallocate() } }

    func process(_ samples: UnsafePointer<Float>, count: Int, speechProbability: Float? = nil) -> [Float] {
        precondition(channelCount == 1)
        var pointer = UnsafeMutablePointer(mutating: samples)
        return withUnsafePointer(to: &pointer) {
            process($0, frameCount: count, speechProbability: speechProbability)[0]
        }
    }

    func process(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount count: Int,
                 speechProbabilities: UnsafePointer<Float>? = nil,
                 speechProbability: Float? = nil) -> [[Float]] {
        clearOutput()
        guard !finished, count > 0 else { return output }
        for frame in 0..<count {
            for channel in 0..<channelCount { buffers[channel][frameCount] = channels[channel][frame] }
            let probability = speechProbabilities.map { $0[frame] } ?? speechProbability
            probabilities[frameCount] = probability ?? 1
            frameHasConfidence = frameHasConfidence || probability != nil
            frameCount += 1
            if frameCount == frameSize { processFrame() }
        }
        return output
    }

    func finish() -> [[Float]] {
        clearOutput()
        guard !finished else { return output }
        finished = true
        if frameCount > 0 { processFrame() }
        return output
    }

    private func clearOutput() {
        for channel in 0..<channelCount { output[channel].removeAll(keepingCapacity: true) }
        outputSpeechProbabilities.removeAll(keepingCapacity: true)
    }

    private func processFrame() {
        buffers.withUnsafeBufferPointer { channels in
            probabilities.withUnsafeBufferPointer { confidence in
                leveler.processLookaheadFrame(channels.baseAddress!, channelCount: channelCount,
                    frameCount: frameCount,
                    speechProbabilities: frameHasConfidence ? confidence.baseAddress : nil)
            }
        }
        for channel in 0..<channelCount {
            output[channel].append(contentsOf: UnsafeBufferPointer(start: buffers[channel], count: frameCount))
        }
        outputSpeechProbabilities.append(contentsOf: probabilities.prefix(frameCount))
        frameCount = 0
        frameHasConfidence = false
    }
}
