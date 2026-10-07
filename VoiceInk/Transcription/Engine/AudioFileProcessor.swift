import AVFoundation
import Foundation
import os

class AudioProcessor {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioProcessor")

    struct AudioFormat {
        static let targetSampleRate: Double = 16000.0
        static let targetChannels: UInt32 = 1
        static let targetBitDepth: UInt32 = 16
    }

    enum AudioProcessingError: LocalizedError {
        case invalidAudioFile
        case conversionFailed
        case exportFailed
        case unsupportedFormat
        case sampleExtractionFailed

        var errorDescription: String? {
            switch self {
            case .invalidAudioFile:
                return String(localized: "The audio file is invalid or corrupted")
            case .conversionFailed:
                return String(localized: "Failed to convert the audio format")
            case .exportFailed:
                return String(localized: "Failed to export the processed audio")
            case .unsupportedFormat:
                return String(localized: "The audio format is not supported")
            case .sampleExtractionFailed:
                return String(localized: "Failed to extract audio samples")
            }
        }
    }

    func processAudioToSamples(
        _ url: URL,
        strength: Float = NormalizationSettings.loadStrength(),
        isolationStrength: Float = VoiceIsolationSettings.loadStrength(),
        blendMode: VoiceIsolationSettings.BlendMode = VoiceIsolationSettings.loadBlendMode()
    ) async throws -> [Float] {
        let samples: [Float]
        do {
            samples = try readUsingAudioFile(url)
        } catch {
            // AVAudioFile can choke on some container/codec combinations that
            // the media stack can otherwise play (e.g. avfaudio error -50 on
            // certain mp4/m4a meeting recordings, issue #799). AVAssetReader
            // is a more resilient fallback for media containers and delivers
            // target LPCM directly, avoiding manual seeking and conversion.
            logger.warning(
                "AVAudioFile pipeline failed for \(url.lastPathComponent, privacy: .public): \(error, privacy: .public). Falling back to AVAssetReader."
            )
            samples = try await readUsingAssetReader(url)
        }

        let pipeline = try SpeechProcessingPipeline(
            sampleRate: 48_000,
            outputSampleRate: AudioFormat.targetSampleRate,
            normalizationStrength: strength,
            isolationStrength: isolationStrength,
            blendMode: blendMode
        )
        var processed: [Float] = []
        // Keep processing bounded and allow cancellation between chunks.
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let count = min(65_536, samples.count - offset)
            samples.withUnsafeBufferPointer {
                processed.append(contentsOf: pipeline.process($0.baseAddress! + offset, count: count))
            }
            offset += count
        }
        processed.append(contentsOf: pipeline.finish())
        return processed
    }

    /// Isolate, optionally EQ, then level each channel in one streaming pass.
    func normalizeAudioFile(
        at url: URL,
        strength: Float = NormalizationSettings.loadStrength(),
        isolationStrength: Float = VoiceIsolationSettings.loadStrength(),
        blendMode: VoiceIsolationSettings.BlendMode = VoiceIsolationSettings.loadBlendMode(),
        equalizerSettings: MicrophoneEqualizerSettings? = nil
    ) throws {
        let inputFile = try AVAudioFile(forReading: url)
        let format = inputFile.processingFormat
        let channelCount = Int(format.channelCount)
        let chunkSize: AVAudioFrameCount = 65_536
        let outputCapacity = chunkSize + AVAudioFrameCount(ceil(format.sampleRate * 0.1)) + 64
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
            throw AudioProcessingError.conversionFailed
        }
        let pipelines = try (0..<channelCount).map { _ in
            try SpeechProcessingPipeline(sampleRate: format.sampleRate,
                normalizationStrength: strength, isolationStrength: isolationStrength,
                blendMode: blendMode, equalizerSettings: equalizerSettings,
                applyNormalization: channelCount == 1)
        }
        var sharedLeveler = StreamingSpeechLeveler(sampleRate: format.sampleRate, strength: strength)
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).normalizing-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        // Close the writer before replacing the original so its header is final.
        do {
            let outputFile = try AVAudioFile(
                forWriting: temporaryURL, settings: inputFile.fileFormat.settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            func write(_ results: [[Float]]) throws {
                guard let count = results.first?.count, count > 0 else { return }
                guard count <= Int(outputCapacity), results.allSatisfy({ $0.count == count }),
                      let channels = outputBuffer.floatChannelData else {
                    throw AudioProcessingError.sampleExtractionFailed
                }
                outputBuffer.frameLength = AVAudioFrameCount(count)
                for channel in 0..<channelCount {
                    results[channel].withUnsafeBufferPointer {
                        channels[channel].update(from: $0.baseAddress!, count: count)
                    }
                }
                if channelCount > 1 {
                    if isolationStrength > 0 {
                        let probabilities = (0..<count).map { frame in
                            pipelines.map { $0.outputSpeechProbabilities[frame] }.max() ?? 0
                        }
                        probabilities.withUnsafeBufferPointer {
                            sharedLeveler.process(channels, channelCount: channelCount,
                                frameCount: count, speechProbabilities: $0.baseAddress)
                        }
                    } else {
                        sharedLeveler.process(channels, channelCount: channelCount, frameCount: count)
                    }
                }
                try outputFile.write(from: outputBuffer)
            }
            while inputFile.framePosition < inputFile.length {
                try inputFile.read(into: buffer, frameCount: chunkSize)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                    throw AudioProcessingError.sampleExtractionFailed
                }
                try write((0..<channelCount).map {
                    pipelines[$0].process(channels[$0], count: Int(buffer.frameLength))
                })
            }
            try write(pipelines.map { $0.finish() })
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    }

    private func readUsingAudioFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: 48_000, channels: AudioFormat.targetChannels, interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 65_536) else {
            throw AudioProcessingError.conversionFailed
        }
        var samples: [Float] = []
        var readError: Error?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard readError == nil, file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: min(requested, input.frameCapacity))
                    inputStatus.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw AudioProcessingError.conversionFailed }
            if output.frameLength > 0 { samples.append(contentsOf: convertToWhisperFormat(output)) }
            if status == .endOfStream { break }
        }
        return samples
    }

    private func readUsingAssetReader(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        // Match the legacy behavior of processing one stream by using the
        // primary audio track rather than attempting to mix multiple tracks.
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioProcessingError.invalidAudioFile
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: AudioFormat.targetChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw AudioProcessingError.conversionFailed
        }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? AudioProcessingError.sampleExtractionFailed
        }

        var samples: [Float] = []
        do {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                try validateAssetReaderOutputFormat(sampleBuffer)

                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                guard byteCount >= MemoryLayout<Float>.size else { continue }

                var chunk = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
                let status = chunk.withUnsafeMutableBytes { destination in
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: destination.count,
                        destination: destination.baseAddress!
                    )
                }
                guard status == kCMBlockBufferNoErr else {
                    throw AudioProcessingError.sampleExtractionFailed
                }
                samples.append(contentsOf: chunk)
            }
        } catch {
            reader.cancelReading()
            throw error
        }

        if reader.status == .failed {
            throw reader.error ?? AudioProcessingError.sampleExtractionFailed
        }
        if reader.status == .cancelled {
            throw CancellationError()
        }
        guard !samples.isEmpty else {
            throw AudioProcessingError.sampleExtractionFailed
        }

        return samples
    }

    private func validateAssetReaderOutputFormat(_ sampleBuffer: CMSampleBuffer) throws {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw AudioProcessingError.sampleExtractionFailed
        }

        let format = streamDescription.pointee
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isBigEndian = (format.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        guard
            format.mFormatID == kAudioFormatLinearPCM,
            abs(format.mSampleRate - 48_000.0) < 1.0,
            format.mChannelsPerFrame == AudioFormat.targetChannels,
            format.mBitsPerChannel == 32,
            isFloat,
            !isBigEndian,
            // Interleaving only changes the byte layout for multi-channel
            // audio; mono is identical either way, so don't reject it.
            format.mChannelsPerFrame == 1 || !isNonInterleaved
        else {
            throw AudioProcessingError.conversionFailed
        }
    }

    private func convertToWhisperFormat(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var samples = Array(repeating: Float(0), count: frameLength)

        if channelCount == 1 {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        } else {
            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                samples[frame] = sum / Float(channelCount)
            }
        }

        return samples
    }


    func saveSamplesAsWav(samples: [Float], to url: URL) throws {
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFormat.targetSampleRate,
            channels: AudioFormat.targetChannels,
            interleaved: true
        )

        guard let outputFormat = outputFormat else {
            throw AudioProcessingError.unsupportedFormat
        }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        )

        guard let buffer = buffer else {
            throw AudioProcessingError.conversionFailed
        }

        // Convert float samples to int16
        let int16Samples = samples.map { max(-1.0, min(1.0, $0)) * Float(Int16.max) }.map { Int16($0) }

        // Copy samples to buffer
        int16Samples.withUnsafeBufferPointer { int16Buffer in
            let int16Pointer = int16Buffer.baseAddress!
            buffer.int16ChannelData![0].update(from: int16Pointer, count: int16Samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Create audio file
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        try audioFile.write(from: buffer)
    }
}
