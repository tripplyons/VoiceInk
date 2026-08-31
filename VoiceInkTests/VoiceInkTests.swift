import AVFoundation
import Foundation
import Testing
@testable import VoiceInk

struct VoiceInkTests {
    @Test func peakNormalizesQuietAudioFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("quiet.wav")
        var samples = [Float](repeating: 0.05, count: 131_072)
        samples[100_000] = -0.2

        let processor = AudioProcessor()
        try processor.saveSamplesAsWav(samples: samples, to: url)
        let peakBefore = try peakAmplitude(in: url)

        try processor.normalizeAudioFile(at: url)
        let peakAfter = try peakAmplitude(in: url)
        let normalizedBackgroundSample = try sample(at: 0, in: url)

        #expect(peakBefore > 0.19 && peakBefore < 0.21)
        #expect(peakAfter > 0.99 && peakAfter <= 1.0)
        #expect(normalizedBackgroundSample > 0.24 && normalizedBackgroundSample < 0.26)
    }

    private func peakAmplitude(in url: URL) throws -> Float {
        let samples = try readSamples(from: url)
        return samples.lazy.map(abs).max() ?? 0
    }

    private func sample(at index: Int, in url: URL) throws -> Float {
        try readSamples(from: url)[index]
    }

    private func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw AudioProcessor.AudioProcessingError.sampleExtractionFailed
        }

        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else {
            throw AudioProcessor.AudioProcessingError.sampleExtractionFailed
        }

        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }
}
