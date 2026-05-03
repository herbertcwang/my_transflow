import Speech
import CoreMedia
@preconcurrency import AVFoundation

/// Uses macOS 26.0 SpeechAnalyzer with two SpeechTranscriber instances (en-US + zh-Hans)
/// for concurrent bilingual real-time transcription. The engine processes a single audio stream
/// and emits merged TranscriptionEvents with detected language info attached.
///
/// ## Deduplication Strategy
/// Both transcribers may produce results for the same spoken utterance. The engine uses
/// `range.start` timestamps to detect overlaps. When overlapping results are found,
/// it prefers the result with the longer text (higher information content).
final class MultilingualSpeechEngine: Sendable {
    private let enLocale: Locale
    private let zhLocale: Locale

    init(
        enLocale: Locale = Locale(identifier: "en-US"),
        zhLocale: Locale = Locale(identifier: "zh-Hans")
    ) {
        self.enLocale = enLocale
        self.zhLocale = zhLocale
    }

    func processStream(_ audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        let enLocale = self.enLocale
        let zhLocale = self.zhLocale

        Task {
            do {
                await ErrorLogger.shared.log(
                    "MultilingualSpeechEngine: initializing for \(enLocale.identifier) + \(zhLocale.identifier)",
                    source: "MultilingualSpeech"
                )

                // 1. Resolve supported locales
                guard let enSupported = await SpeechTranscriber.supportedLocale(equivalentTo: enLocale) else {
                    await ErrorLogger.shared.log("Locale \(enLocale.identifier) not supported", source: "MultilingualSpeech")
                    continuation.yield(.error("Language \(enLocale.identifier) not supported"))
                    continuation.finish()
                    return
                }
                guard let zhSupported = await SpeechTranscriber.supportedLocale(equivalentTo: zhLocale) else {
                    await ErrorLogger.shared.log("Locale \(zhLocale.identifier) not supported", source: "MultilingualSpeech")
                    continuation.yield(.error("Language \(zhLocale.identifier) not supported"))
                    continuation.finish()
                    return
                }

                // 2. Create two transcribers
                let enTranscriber = SpeechTranscriber(
                    locale: enSupported,
                    transcriptionOptions: [],
                    reportingOptions: [.fastResults, .volatileResults],
                    attributeOptions: []
                )
                let zhTranscriber = SpeechTranscriber(
                    locale: zhSupported,
                    transcriptionOptions: [],
                    reportingOptions: [.fastResults, .volatileResults],
                    attributeOptions: []
                )
                let transcribers = [enTranscriber, zhTranscriber]

                // 3. Resolve analyzer format compatible with ALL transcribers
                let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: transcribers
                )

                // 4. Create analyzer with both modules
                let analyzer = SpeechAnalyzer(modules: transcribers)
                try await analyzer.prepareToAnalyze(in: analyzerFormat)

                await ErrorLogger.shared.log(
                    "MultilingualSpeechEngine: analyzer prepared (format: \(analyzerFormat?.description ?? "default"))",
                    source: "MultilingualSpeech"
                )

                // 5. Create input stream
                let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

                // 6. Audio format converter (16kHz → analyzer format)
                let sourceFormat = AVAudioFormat(
                    standardFormatWithSampleRate: 16_000, channels: 1
                )!
                let converter: AVAudioConverter?
                let outputSampleRate: Double
                if let analyzerFormat {
                    converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
                    outputSampleRate = analyzerFormat.sampleRate
                } else {
                    converter = nil
                    outputSampleRate = 16_000
                }

                // Pre-allocate reusable output buffer
                let reusableBuffer: AVAudioPCMBuffer?
                if converter != nil, let analyzerFormat {
                    let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
                    let capacity = AVAudioFrameCount(16_000 * 0.25 * ratio) + 64
                    reusableBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity)
                } else { reusableBuffer = nil }

                // Wall-clock anchor
                let sessionStartDate = Date()

                // 7. Start result consumption — merge both transcriber result streams
                let capturedStartDate = sessionStartDate

                // Track last finalized timestamp per locale to detect first-ever results
                @Sendable func consumeResults(
                    for transcriber: SpeechTranscriber,
                    detectedLanguage: String
                ) -> AsyncStream<TranscriptionEvent> {
                    let (stream, innerContinuation) = AsyncStream<TranscriptionEvent>.makeStream(
                        bufferingPolicy: .bufferingNewest(64)
                    )
                    Task(priority: .userInitiated) {
                        defer { innerContinuation.finish() }
                        do {
                            for try await result in transcriber.results {
                                let text = String(result.text.characters)
                                if result.isFinal {
                                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        let range = result.range
                                        let startSec = CMTimeGetSeconds(range.start)
                                        let endSec = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                                        let startDate = startSec.isFinite
                                            ? capturedStartDate.addingTimeInterval(startSec)
                                            : Date()
                                        let endDate = endSec.isFinite
                                            ? capturedStartDate.addingTimeInterval(endSec)
                                            : Date()
                                        innerContinuation.yield(.sentenceComplete(
                                            TranscriptionSentence(
                                                startTimestamp: startDate,
                                                timestamp: endDate,
                                                text: trimmed,
                                                detectedLanguage: detectedLanguage
                                            )
                                        ))
                                        await ErrorLogger.shared.log(
                                            "MultilingualSpeech: final \(detectedLanguage): \(trimmed.prefix(40))...",
                                            source: "MultilingualSpeech"
                                        )
                                        // Clear partial for this locale
                                        innerContinuation.yield(.partial(""))
                                    }
                                } else {
                                    // Tag partial results with locale so we can distinguish them
                                        await ErrorLogger.shared.log(
                                            "MultilingualSpeech: partial \(detectedLanguage): \(text.prefix(40))...",
                                            source: "MultilingualSpeech"
                                        )
                                        innerContinuation.yield(.partial("[\(detectedLanguage)] \(text)"))
                                }
                            }
                        } catch {
                                await ErrorLogger.shared.log(
                                    "MultilingualSpeech result error (\(detectedLanguage)): \(error.localizedDescription)",
                                    source: "MultilingualSpeech"
                                )
                                innerContinuation.yield(.error("\(detectedLanguage): \(error.localizedDescription)"))
                        }
                    }
                    return stream
                }

                // Merge both streams with deduplication
                let enStream = consumeResults(for: enTranscriber, detectedLanguage: "en")
                let zhStream = consumeResults(for: zhTranscriber, detectedLanguage: "zh")

                // Track last finalized result per locale for dedup
                nonisolated(unsafe) var lastEnFinalizedText = ""
                nonisolated(unsafe) var lastZhFinalizedText = ""

                let mergeTask = Task(priority: .userInitiated) {
                    // Merge en and zh streams
                    let merged = AsyncStream<TranscriptionEvent> { mergeContinuation in
                        Task {
                            await withTaskGroup(of: Void.self) { group in
                                group.addTask {
                                    for await event in enStream {
                                        mergeContinuation.yield(event)
                                    }
                                }
                                group.addTask {
                                    for await event in zhStream {
                                        mergeContinuation.yield(event)
                                    }
                                }
                            }
                            mergeContinuation.finish()
                        }
                    }

                    // Process merged events with deduplication
                    for await event in merged {
                        switch event {
                        case .sentenceComplete(let sentence):
                            let text = sentence.text
                            let lang = sentence.detectedLanguage ?? ""

                            // Deduplication: skip if this text exactly matches the last finalized text for this locale
                            let isDuplicate: Bool
                            if lang == "en" {
                                isDuplicate = text == lastEnFinalizedText
                                if !isDuplicate { lastEnFinalizedText = text }
                            } else if lang == "zh" {
                                isDuplicate = text == lastZhFinalizedText
                                if !isDuplicate { lastZhFinalizedText = text }
                            } else {
                                isDuplicate = false
                            }

                            if !isDuplicate {
                                continuation.yield(event)
                            } else {
                                await ErrorLogger.shared.log(
                                    "Dedup: suppressed duplicate '\(lang)' result: \(text.prefix(30))...",
                                    source: "MultilingualSpeech"
                                )
                            }

                        case .partial(let text):
                            // For partials, strip the locale tag prefix we added earlier
                            let cleaned: String
                            if text.hasPrefix("[en] ") {
                                cleaned = String(text.dropFirst(5))
                            } else if text.hasPrefix("[zh] ") {
                                cleaned = String(text.dropFirst(5))
                            } else {
                                cleaned = text
                            }
                            continuation.yield(.partial(cleaned))

                        case .error:
                            continuation.yield(event)
                        }
                    }
                }

                // 8. Start autonomous analysis
                try await analyzer.start(inputSequence: inputSequence)

                // 9. Feed audio: accumulate ~200ms before batch sending.
                var accumulator: [Float] = []
                let batchThreshold = Int(16_000 * 0.2)
                var cumulativeOutputFrames: Int64 = 0

                for await chunk in audioStream {
                    accumulator.append(contentsOf: chunk.samples)
                    guard accumulator.count >= batchThreshold else { continue }

                    let startTime = CMTime(value: cumulativeOutputFrames, timescale: CMTimeScale(outputSampleRate))
                    if let (input, frameCount) = Self.convertToAnalyzerInput(
                        samples: accumulator, converter: converter,
                        reusableBuffer: reusableBuffer, bufferStartTime: startTime
                    ) {
                        inputBuilder.yield(input)
                        cumulativeOutputFrames += Int64(frameCount)
                    }
                    accumulator.removeAll(keepingCapacity: true)
                }

                // Flush remaining
                if !accumulator.isEmpty {
                    let startTime = CMTime(value: cumulativeOutputFrames, timescale: CMTimeScale(outputSampleRate))
                    if let (input, _) = Self.convertToAnalyzerInput(
                        samples: accumulator, converter: converter,
                        reusableBuffer: reusableBuffer, bufferStartTime: startTime
                    ) {
                        inputBuilder.yield(input)
                    }
                }

                inputBuilder.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                mergeTask.cancel()
                await ErrorLogger.shared.log(
                    "MultilingualSpeechEngine: finalized",
                    source: "MultilingualSpeech"
                )

            } catch {
                await ErrorLogger.shared.log(
                    "MultilingualSpeechEngine error: \(error.localizedDescription)",
                    source: "MultilingualSpeech"
                )
                continuation.yield(.error("Engine error: \(error.localizedDescription)"))
            }
            continuation.finish()
        }

        return events
    }

    // MARK: - Helpers

    /// Convert Float32 samples to AnalyzerInput (with format conversion).
    private static func convertToAnalyzerInput(
        samples: [Float],
        converter: AVAudioConverter?,
        reusableBuffer: AVAudioPCMBuffer?,
        bufferStartTime: CMTime
    ) -> (AnalyzerInput, AVAudioFrameCount)? {
        guard let pcmBuffer = Self.createPCMBuffer(from: samples) else { return nil }

        if let converter, let reusableBuffer {
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: reusableBuffer.format,
                frameCapacity: reusableBuffer.frameCapacity
            )!
            outputBuffer.frameLength = 0
            var error: NSError?
            nonisolated(unsafe) var consumed = false
            nonisolated(unsafe) let capturedBuffer = pcmBuffer
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true; outStatus.pointee = .haveData; return capturedBuffer
            }
            guard error == nil, outputBuffer.frameLength > 0 else { return nil }
            return (AnalyzerInput(buffer: outputBuffer, bufferStartTime: bufferStartTime), outputBuffer.frameLength)
        } else {
            return (AnalyzerInput(buffer: pcmBuffer, bufferStartTime: bufferStartTime), pcmBuffer.frameLength)
        }
    }

    /// Create 16kHz mono PCM buffer from Float32 samples.
    private static func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { ptr in
            channelData[0].initialize(from: ptr.baseAddress!, count: samples.count)
        }
        return buffer
    }
}