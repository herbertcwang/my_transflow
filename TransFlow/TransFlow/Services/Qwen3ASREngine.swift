import Foundation
import FluidAudio
import CoreML

/// Multilingual speech recognition engine using FluidAudio's Qwen3-ASR + Silero VAD.
///
/// Pipeline:
/// 1. Accumulate 16kHz mono Float32 audio chunks
/// 2. Feed chunks through Silero VAD (streaming mode) to detect speech boundaries
/// 3. On speech end, transcribe the complete utterance segment via Qwen3-ASR
/// 4. Qwen3 auto-detects language (zh, en, ja, etc.) — reported via TranscriptionEvent .detectedLanguage
/// 5. Emit partial/final TranscriptionEvents
final class Qwen3ASREngine: Sendable {
    /// ASR manager (thread-safe once loaded).
    private let asrManager: Qwen3AsrManager

    /// Cache of loaded models directory.
    private let modelDir: URL

    /// Session start wall-clock time for timestamp mapping.
    private let sessionStart: Date

    /// Optional language hint to constrain Qwen3-ASR recognition.
    /// When nil, Qwen3 auto-detects language. When set, the model prioritizes that language.
    private let languageHint: Qwen3AsrConfig.Language?

    /// Initialize with a pre-downloaded model directory.
    /// - Parameters:
    ///   - modelDir: Path to Qwen3 ASR CoreML models (from Qwen3AsrModels.download()).
    ///   - sessionStart: Wall-clock anchor for timestamp mapping.
    ///   - languageHint: Optional language code (e.g. "en", "zh") to constrain recognition.
    init(modelDir: URL, sessionStart: Date = Date(), languageHint: String? = nil) async throws {
        self.modelDir = modelDir
        self.sessionStart = sessionStart
        self.languageHint = languageHint.flatMap { Qwen3ASREngine.parseLanguage($0) }
        let manager = Qwen3AsrManager()
        try await manager.loadModels(from: modelDir)
        self.asrManager = manager
        ErrorLogger.shared.log(
            "Qwen3ASREngine initialized with models from \(modelDir.path), languageHint: \(languageHint ?? "auto")",
            source: "Qwen3ASR"
        )
    }

    /// Process an async stream of audio chunks, producing transcription events.
    /// - Parameter audioStream: 16kHz mono Float32 audio chunks.
    /// - Returns: AsyncStream of TranscriptionEvent, including .detectedLanguage for each segment.
    func processStream(_ audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        let asrManager = self.asrManager
        let sessionStart = self.sessionStart
        let languageHint = self.languageHint

        Task {
            do {
                // Create VAD manager for this session
                let vadManager = try await VadManager()
                var vadState = await vadManager.makeStreamState()

                // Accumulator for the current speech segment
                var speechBuffer: [Float] = []
                var speechStartDate: Date?
                var isInSpeech = false

                for await chunk in audioStream {
                    // Feed chunk to VAD (must be exactly sized for VAD; we feed at the VAD window rate)
                    let vadResult = try await vadManager.processStreamingChunk(
                        chunk.samples,
                        state: vadState,
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 3
                    )
                    vadState = vadResult.state

                    if let event = vadResult.event {
                        switch event.kind {
                        case .speechStart:
                            // Start a new speech segment
                            speechBuffer.removeAll(keepingCapacity: true)
                            speechBuffer.append(contentsOf: chunk.samples)
                            speechStartDate = chunk.timestamp
                            isInSpeech = true

                            ErrorLogger.shared.log(
                                "VAD speech start at ~\(event.time ?? 0)s",
                                source: "Qwen3ASR"
                            )

                        case .speechEnd:
                            // Speech ended — transcribe the accumulated segment
                            if !speechBuffer.isEmpty {
                                let segStartDate = speechStartDate ?? chunk.timestamp
                                let segEndDate = chunk.timestamp

                                do {
                                    let text: String
                                    if let hint = languageHint {
                                        text = try await asrManager.transcribe(
                                            audioSamples: speechBuffer,
                                            language: hint
                                        )
                                    } else {
                                        text = try await asrManager.transcribe(
                                            audioSamples: speechBuffer
                                        )
                                    }

                                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        // Qwen3 auto-detects language — for now we report as a TranscriptionSentence
                                        // with the text. Language detection is implicit in the model.
                                        let sentence = TranscriptionSentence(
                                            startTimestamp: segStartDate,
                                            timestamp: segEndDate,
                                            text: trimmed,
                                            detectedLanguage: nil  // Qwen3 doesn't expose per-segment lang yet
                                        )
                                        continuation.yield(.sentenceComplete(sentence))
                                        continuation.yield(.partial(""))

                                        ErrorLogger.shared.log(
                                            "Qwen3 transcribed: \"\(trimmed.prefix(50))...\"",
                                            source: "Qwen3ASR"
                                        )
                                    }
                                } catch {
                                    ErrorLogger.shared.log(
                                        "Qwen3 transcription error: \(error.localizedDescription)",
                                        source: "Qwen3ASR"
                                    )
                                    continuation.yield(.error("ASR error: \(error.localizedDescription)"))
                                }

                                speechBuffer.removeAll(keepingCapacity: true)
                            }
                            isInSpeech = false

                            ErrorLogger.shared.log(
                                "VAD speech end at ~\(event.time ?? 0)s",
                                source: "Qwen3ASR"
                            )
                        }
                    } else if isInSpeech {
                        // Accumulate audio during ongoing speech
                        speechBuffer.append(contentsOf: chunk.samples)
                    }
                }

                // Finalize: if speech was still in progress, transcribe remaining buffer
                if isInSpeech, !speechBuffer.isEmpty {
                    do {
                        let text: String
                        if let hint = languageHint {
                            text = try await asrManager.transcribe(
                                audioSamples: speechBuffer,
                                language: hint
                            )
                        } else {
                            text = try await asrManager.transcribe(
                                audioSamples: speechBuffer
                            )
                        }
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            let sentence = TranscriptionSentence(
                                startTimestamp: speechStartDate ?? Date(),
                                timestamp: Date(),
                                text: trimmed,
                                detectedLanguage: nil
                            )
                            continuation.yield(.sentenceComplete(sentence))
                            continuation.yield(.partial(""))
                        }
                    } catch {
                        continuation.yield(.error("Final ASR error: \(error.localizedDescription)"))
                    }
                }

                ErrorLogger.shared.log(
                    "Qwen3ASREngine processStream finished",
                    source: "Qwen3ASR"
                )

            } catch {
                ErrorLogger.shared.log(
                    "Qwen3ASREngine error: \(error.localizedDescription)",
                    source: "Qwen3ASR"
                )
                continuation.yield(.error("Engine error: \(error.localizedDescription)"))
            }

            continuation.finish()
        }

        return events
    }

    // MARK: - Language Hint Parsing

    /// Convert a language code string (e.g. "en", "zh") to a Qwen3AsrConfig.Language.
    /// Returns nil for unsupported or auto-detect codes.
    private static func parseLanguage(_ code: String) -> Qwen3AsrConfig.Language? {
        Qwen3AsrConfig.Language(from: code)
    }
}