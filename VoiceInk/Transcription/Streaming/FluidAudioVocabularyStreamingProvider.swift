import FluidAudio
import Foundation
import os

/// FluidAudio's sliding-window pipeline with CTC-backed custom vocabulary rescoring.
final class FluidAudioVocabularyStreamingProvider: StreamingTranscriptionProvider {
    private let fluidAudioService: FluidAudioTranscriptionService
    private let vocabularyWords: [String]
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioVocabularyStreaming")
    private var manager: SlidingWindowAsrManager?
    private var updatesTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    var stopDisposition: StreamingStopDisposition { .finalizeStreaming }

    init(fluidAudioService: FluidAudioTranscriptionService, vocabularyWords: [String]) {
        self.fluidAudioService = fluidAudioService
        self.vocabularyWords = vocabularyWords

        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        updatesTask?.cancel()
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        let version = FluidAudioModelManager.asrVersion(for: model.name)
        let models = try await fluidAudioService.getOrLoadModels(for: version)
        guard let vocabulary = try await FluidAudioVocabulary.load(words: vocabularyWords) else {
            throw ASRError.processingFailed("Custom vocabulary is empty")
        }

        let languageHint = FluidAudioTranscriptionService.languageHint(from: language, model: model)
        let manager = SlidingWindowAsrManager(config: .streaming.applying(language: languageHint))
        try await manager.loadModels(models)
        try await manager.configureVocabularyBoosting(
            vocabulary: vocabulary.context,
            ctcModels: vocabulary.ctcModels
        )

        let updates = await manager.transcriptionUpdates
        updatesTask = Task { [weak self] in
            for await update in updates where !update.text.isEmpty {
                self?.eventsContinuation?.yield(.partial(text: update.text))
            }
        }

        try await manager.startStreaming()
        self.manager = manager
        eventsContinuation?.yield(.sessionStarted)
        logger.notice("FluidAudio vocabulary streaming started with \(self.vocabularyWords.count, privacy: .public) terms")
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let buffer = PCMAudioConverter.pcmBuffer(fromPCM16Data: data) else { return }
        await manager?.streamAudio(buffer)
    }

    func commit() async throws {
        guard let manager else { throw ASRError.notInitialized }
        let text = try await manager.finish()
        eventsContinuation?.yield(.committed(text: TextNormalizer.shared.normalizeSentence(text)))
    }

    func disconnect() async {
        updatesTask?.cancel()
        updatesTask = nil
        await manager?.cleanup()
        manager = nil
        eventsContinuation?.finish()
    }
}
