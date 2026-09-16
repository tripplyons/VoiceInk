import AVFoundation
import Foundation

struct MicrophoneEqualizer {
    private var filtersByChannel: [[BiquadFilter]]

    init(settings: MicrophoneEqualizerSettings, sampleRate: Double, channelCount: Int) {
        filtersByChannel = (0..<channelCount).map { _ in
            Self.makeFilters(settings: settings, sampleRate: sampleRate)
        }
    }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard filtersByChannel.indices.contains(channel) else { return }

        for sampleIndex in 0..<count {
            var sample = samples[sampleIndex]
            for filterIndex in filtersByChannel[channel].indices {
                sample = filtersByChannel[channel][filterIndex].process(sample)
            }
            samples[sampleIndex] = sample
        }
    }

    mutating func process(_ samples: inout [Float], channel: Int = 0) {
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            process(baseAddress, count: buffer.count, channel: channel)
        }
    }

    private static func makeFilters(
        settings: MicrophoneEqualizerSettings,
        sampleRate: Double
    ) -> [BiquadFilter] {
        var filters = [
            BiquadFilter.highPass(
                frequency: Double(settings.highPassFrequency),
                sampleRate: sampleRate
            )
        ]

        filters.append(contentsOf: zip(Self.bandFrequencies, settings.bandGains).map { band in
            BiquadFilter.peaking(
                frequency: Double(band.0),
                gainDecibels: Double(band.1),
                sampleRate: sampleRate
            )
        })
        filters.append(
            BiquadFilter.lowPass(
                frequency: Double(settings.lowPassFrequency),
                sampleRate: sampleRate
            )
        )
        return filters
    }

    private static let bandFrequencies = MicrophoneEqualizerSettings.bandFrequencies
}

private struct BiquadFilter {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float

    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }

    static func highPass(frequency: Double, sampleRate: Double) -> Self {
        let omega = normalizedAngularFrequency(frequency, sampleRate: sampleRate)
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * butterworthQ)
        return normalized(
            b0: (1 + cosine) / 2,
            b1: -(1 + cosine),
            b2: (1 + cosine) / 2,
            a0: 1 + alpha,
            a1: -2 * cosine,
            a2: 1 - alpha
        )
    }

    static func lowPass(frequency: Double, sampleRate: Double) -> Self {
        let omega = normalizedAngularFrequency(frequency, sampleRate: sampleRate)
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * butterworthQ)
        return normalized(
            b0: (1 - cosine) / 2,
            b1: 1 - cosine,
            b2: (1 - cosine) / 2,
            a0: 1 + alpha,
            a1: -2 * cosine,
            a2: 1 - alpha
        )
    }

    static func peaking(frequency: Double, gainDecibels: Double, sampleRate: Double) -> Self {
        let omega = normalizedAngularFrequency(frequency, sampleRate: sampleRate)
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * equalizerQ)
        let amplitude = pow(10, gainDecibels / 40)
        return normalized(
            b0: 1 + alpha * amplitude,
            b1: -2 * cosine,
            b2: 1 - alpha * amplitude,
            a0: 1 + alpha / amplitude,
            a1: -2 * cosine,
            a2: 1 - alpha / amplitude
        )
    }

    private static func normalizedAngularFrequency(_ frequency: Double, sampleRate: Double) -> Double {
        let safeFrequency = min(max(frequency, 10), sampleRate * 0.49)
        return 2 * .pi * safeFrequency / sampleRate
    }

    private static func normalized(
        b0: Double,
        b1: Double,
        b2: Double,
        a0: Double,
        a1: Double,
        a2: Double
    ) -> Self {
        Self(
            b0: Float(b0 / a0),
            b1: Float(b1 / a0),
            b2: Float(b2 / a0),
            a1: Float(a1 / a0),
            a2: Float(a2 / a0)
        )
    }

    private static let butterworthQ = sqrt(0.5)
    private static let equalizerQ = 1.0
}

extension AudioProcessor {
    func processMicrophoneRecording(
        at url: URL,
        settings: MicrophoneEqualizerSettings
    ) throws {
        guard settings.isEnabled else {
            try normalizeAudioFile(at: url)
            return
        }

        let peak = try equalizedPeakAmplitude(in: url, settings: settings)
        guard peak > 0 else { return }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).equalizing-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try writeEqualizedAudio(
            from: url,
            to: temporaryURL,
            settings: settings,
            gain: 1 / peak
        )
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    }

    private func equalizedPeakAmplitude(
        in url: URL,
        settings: MicrophoneEqualizerSettings
    ) throws -> Float {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            throw AudioProcessingError.sampleExtractionFailed
        }

        var equalizer = MicrophoneEqualizer(
            settings: settings,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
        var peak: Float = 0

        while audioFile.framePosition < audioFile.length {
            try audioFile.read(into: buffer, frameCount: chunkSize)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw AudioProcessingError.sampleExtractionFailed
            }

            for channel in 0..<Int(format.channelCount) {
                equalizer.process(channels[channel], count: Int(buffer.frameLength), channel: channel)
                let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
                peak = max(peak, samples.lazy.map(abs).max() ?? 0)
            }
        }
        return peak
    }

    private func writeEqualizedAudio(
        from sourceURL: URL,
        to destinationURL: URL,
        settings: MicrophoneEqualizerSettings,
        gain: Float
    ) throws {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let format = sourceFile.processingFormat
        let outputFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: sourceFile.fileFormat.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            throw AudioProcessingError.conversionFailed
        }
        var equalizer = MicrophoneEqualizer(
            settings: settings,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )

        while sourceFile.framePosition < sourceFile.length {
            try sourceFile.read(into: buffer, frameCount: chunkSize)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw AudioProcessingError.sampleExtractionFailed
            }

            for channel in 0..<Int(format.channelCount) {
                equalizer.process(channels[channel], count: Int(buffer.frameLength), channel: channel)
                for frame in 0..<Int(buffer.frameLength) {
                    channels[channel][frame] *= gain
                }
            }
            try outputFile.write(from: buffer)
        }
    }
}
