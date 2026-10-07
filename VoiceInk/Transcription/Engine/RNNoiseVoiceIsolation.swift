import Foundation
import RNNoise

/// RNNoise consumes 480-sample frames of 48 kHz float PCM in Int16 units.
/// This pinned model has a two-frame analysis/synthesis delay. Delay the dry
/// signal too, discard startup output, and flush the final frames on stop.
final class RNNoiseVoiceIsolation {
    static let sampleRate: Double = 48_000
    static let frameSize = 480
    private static let delayFrames = 2
    private let state: OpaquePointer
    private let strength: Float
    private let blendMode: VoiceIsolationSettings.BlendMode
    private var input = [Float](repeating: 0, count: frameSize)
    private var output = [Float](repeating: 0, count: frameSize)
    private var dry = [[Float]](repeating: [Float](repeating: 0, count: frameSize), count: delayFrames)
    private var inputCount = 0
    private var received = 0
    private var emitted = 0
    private var frameIndex = 0
    private var finished = false

    init(strength: Float, blendMode: VoiceIsolationSettings.BlendMode = .linear) throws {
        self.blendMode = blendMode
        self.strength = VoiceIsolationSettings.validatedStrength(strength)
        guard let state = rnnoise_create(nil) else { throw IsolationError.initializationFailed }
        self.state = state
        precondition(Int(rnnoise_get_frame_size()) == Self.frameSize)
    }

    deinit { rnnoise_destroy(state) }

    func process(_ sample: Float, emit: (UnsafePointer<Float>, Int, Float) -> Void) {
        guard !finished else { return }
        input[inputCount] = sample.isFinite ? sample * 32768 : 0
        inputCount += 1
        received += 1
        if inputCount == Self.frameSize { processFrame(emit: emit) }
    }

    func finish(emit: (UnsafePointer<Float>, Int, Float) -> Void) {
        guard !finished else { return }
        finished = true
        if inputCount > 0 {
            for index in inputCount..<Self.frameSize { input[index] = 0 }
            processFrame(emit: emit)
        }
        for _ in 0..<Self.delayFrames {
            input = [Float](repeating: 0, count: Self.frameSize)
            processFrame(emit: emit)
        }
    }

    private func processFrame(emit: (UnsafePointer<Float>, Int, Float) -> Void) {
        let probability = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                rnnoise_process_frame(state, destination.baseAddress!, source.baseAddress!)
            }
        }
        let slot = frameIndex % Self.delayFrames
        let count = frameIndex >= Self.delayFrames ? min(Self.frameSize, received - emitted) : 0
        for index in 0..<Self.frameSize {
            let original = dry[slot][index] / 32768
            let isolated = output[index] / 32768
            output[index] = blendMode.mix(original: original, isolated: isolated, strength: strength)
            dry[slot][index] = input[index]
        }
        if count > 0 {
            output.withUnsafeBufferPointer { emit($0.baseAddress!, count, probability) }
            emitted += count
        }
        frameIndex += 1
        inputCount = 0
    }

    enum IsolationError: LocalizedError {
        case initializationFailed
        var errorDescription: String? { "Failed to initialize RNNoise voice isolation." }
    }
}
