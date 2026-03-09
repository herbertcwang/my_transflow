import Foundation
import os
import FluidAudio

/// Wraps FluidAudio's `DiarizerManager` + `AudioStream` for real-time streaming speaker diarization.
///
/// Key parameters (derived from the speaker_diarization_guide):
/// - `clusteringThreshold: 0.5` — DiarizerManager internally computes
///   `speakerThreshold = threshold * 1.2 = 0.6` and `embeddingThreshold = threshold * 0.8 = 0.4`.
///   Setting this too high (e.g. 0.8 → speakerThreshold 0.96) makes it nearly impossible
///   to distinguish different speakers.
/// - `chunkDuration: 10.0` — 10s chunks balance latency and accuracy; 5s is too short
///   and often contains only one speaker.
/// - `chunkSkip: 3.0` — Overlap between chunks helps capture speaker transitions.
///
/// Must be used on `@MainActor` (FluidAudio types require it).
@MainActor
final class RealtimeDiarizationService {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.transflow",
        category: "RealtimeDiarization"
    )

    struct SpeakerSegment: Sendable {
        let speakerId: String
        let startTime: Float
        let endTime: Float
    }

    typealias DiarizationCallback = @Sendable ([SpeakerSegment]) -> Void

    private let diarizer: DiarizerManager
    private var audioStream: AudioStream
    private var callback: DiarizationCallback?
    private var isActive = false
    private var chunkCount = 0

    init() throws {
        let config = DiarizerConfig(
            clusteringThreshold: 0.5,
            minSpeechDuration: 0.5,
            minSilenceGap: 0.3
        )
        diarizer = DiarizerManager(config: config)
        audioStream = try AudioStream(
            chunkDuration: 10.0,
            chunkSkip: 3.0,
            streamStartTime: 0.0,
            chunkingStrategy: .useFixedSkip
        )
    }

    /// Initialize the diarizer with pre-loaded models. Must be called before `start()`.
    func initialize(models: DiarizerModels) {
        diarizer.initialize(models: models)
        Self.logger.info("RealtimeDiarizationService initialized with models")
    }

    /// Start the diarization pipeline. The callback is invoked on each processed chunk.
    func start(onSegments: @escaping DiarizationCallback) throws {
        guard !isActive else { return }
        isActive = true
        chunkCount = 0
        callback = onSegments

        audioStream = try AudioStream(
            chunkDuration: 10.0,
            chunkSkip: 3.0,
            streamStartTime: 0.0,
            chunkingStrategy: .useFixedSkip
        )

        audioStream.bind { [weak self] chunk, time in
            guard let self else { return }
            self.chunkCount += 1
            do {
                let result = try self.diarizer.performCompleteDiarization(chunk, atTime: time)
                let segments = result.segments.map { seg in
                    SpeakerSegment(
                        speakerId: seg.speakerId,
                        startTime: seg.startTimeSeconds,
                        endTime: seg.endTimeSeconds
                    )
                }

                let uniqueSpeakers = Set(segments.map(\.speakerId))
                let totalTracked = self.diarizer.speakerManager.speakerCount
                Self.logger.info("Chunk #\(self.chunkCount) at \(time, format: .fixed(precision: 1))s: \(segments.count) segments, \(uniqueSpeakers.count) speakers in chunk [\(uniqueSpeakers.sorted().joined(separator: ", "))], \(totalTracked) total tracked")

                if let timings = result.timings {
                    Self.logger.debug("  Timings — seg: \(timings.segmentationSeconds, format: .fixed(precision: 3))s, emb: \(timings.embeddingExtractionSeconds, format: .fixed(precision: 3))s, cluster: \(timings.speakerClusteringSeconds, format: .fixed(precision: 3))s")
                }

                self.callback?(segments)
            } catch {
                Self.logger.error("Diarization chunk #\(self.chunkCount) failed: \(error.localizedDescription)")
            }
        }

        Self.logger.info("RealtimeDiarizationService started (threshold=0.5, chunk=10s, skip=3s)")
    }

    /// Feed audio samples to the diarization pipeline.
    func feedAudio(_ samples: [Float]) {
        guard isActive else { return }
        do {
            try audioStream.write(from: samples)
        } catch {
            Self.logger.error("AudioStream write failed: \(error.localizedDescription)")
        }
    }

    /// Stop diarization and reset state.
    func stop() {
        let finalCount = diarizer.speakerManager.speakerCount
        let chunks = self.chunkCount
        Self.logger.info("RealtimeDiarizationService stopping — \(chunks) chunks processed, \(finalCount) speakers identified")
        isActive = false
        callback = nil
        diarizer.speakerManager.reset()
    }

    /// Current speaker count being tracked.
    var speakerCount: Int {
        diarizer.speakerManager.speakerCount
    }
}
