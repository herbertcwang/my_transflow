import SwiftUI
import Speech
import Translation

/// Main ViewModel coordinating all services: audio capture, Apple Speech multilingual ASR, and recording.
@Observable
@MainActor
final class TransFlowViewModel {
    // MARK: - Published State

    /// Completed transcription sentences history
    var sentences: [TranscriptionSentence] = []
    /// Current volatile partial text
    var currentPartialText: String = ""
    /// Current listening state
    var listeningState: ListeningState = .idle
    /// Current audio level (0-1)
    var audioLevel: Float = 0
    /// Audio level waveform history
    var audioLevelHistory: [Float] = Array(repeating: 0, count: 30)
    /// Selected audio source
    var audioSource: AudioSourceType = .microphone
    /// Available apps for audio capture
    var availableApps: [AppAudioTarget] = []
    /// Error message
    var errorMessage: String?
    /// Whether to show the "model not ready" alert prompting user to go to Settings.
    var showModelNotReadyAlert: Bool = false
    /// Microphone permission granted
    var micPermissionGranted: Bool = false

    /// Apple Speech model manager for bilingual EN/ZH.
    let speechModelManager = SpeechModelManager.shared

    /// Translation service for Chinese→English live translation.
    @ObservationIgnored private let translationService = TranslationService()
    var translationEnabled: Bool {
        translationService.isEnabled
    }
    var partialTranslation: String {
        translationService.currentPartialTranslation
    }
    var translationServiceConfiguration: TranslationSession.Configuration? {
        translationService.configuration
    }

    /// JSONL persistence store for the current session.
    let jsonlStore = JSONLStore()

    /// Whether real-time speaker diarization is active this session.
    var isDiarizationEnabled: Bool = false

    /// Active speaker count from the current diarization session.
    var activeSpeakerCount: Int = 0

    // MARK: - Private

    private let audioCaptureService = AudioCaptureService()
    private let audioRecordingService = AudioRecordingService()
    private var stopAudioCapture: (@Sendable () -> Void)?
    private var listeningTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?
    private var lifecycleObserver: (any NSObjectProtocol)?

    /// Current recording file name (set while recording is active).
    private var currentRecordingFileName: String?

    /// When the current partial utterance started (for flushing on stop).
    private var partialStartTimestamp: Date?

    /// Session start time for converting absolute timestamps to relative offsets.
    private var sessionStartTime: Date?

    /// Realtime diarization service.
    private var realtimeDiarizationService: RealtimeDiarizationService?

    /// Diarization segments received so far, used for backfilling sentences.
    private var diarizationSegments: [RealtimeDiarizationService.SpeakerSegment] = []


    // MARK: - Initialization

    init() {
        Task {
            await initialize()
        }
        setupLifecycleObserver()
        setupTranslationObserver()
    }

    /// Set up translation service defaults: source=Chinese → target=English.
    private func setupTranslationObserver() {
        translationService.updateSourceLanguage(from: Locale(identifier: "zh-Hans"))
        translationService.targetLanguage = Locale.Language(identifier: "en")
    }

    /// Enable or disable live translation.
    func setTranslationEnabled(_ enabled: Bool) {
        translationService.isEnabled = enabled
        if enabled {
            Task { await translationService.refreshAndAutoSelect(force: true) }
        } else {
            translationService.clearSession()
        }
    }

    /// Called from .translationTask in ContentView.
    func handleTranslationSession(_ session: TranslationSession) async {
        await translationService.handleSession(session)
    }

    private func initialize() async {
        jsonlStore.createSession()
        micPermissionGranted = await AudioCaptureService.requestPermission()
        DiarizationModelManager.shared.checkStatus()
        await refreshAvailableApps()
        // Apple Speech model statuses will be checked lazily on first startListening()
    }

    private func setupLifecycleObserver() {
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                ErrorLogger.shared.log(
                    "App became active — listeningState=\(self.listeningState)",
                    source: "Transcription"
                )
                guard self.listeningState == .idle else { return }
                DiarizationModelManager.shared.checkStatus()
                // Re-validate speech model statuses (handles stale AssetInventory cache)
                await self.speechModelManager.checkBilingualStatus()
            }
        }
    }

    // MARK: - App Audio

    func refreshAvailableApps() async {
        availableApps = await AppAudioCaptureService.availableApps()
    }

    // MARK: - Listening

    func startListening() {
        guard listeningState == .idle else { return }
        listeningState = .starting
        ErrorLogger.shared.log(
            "startListening: source=\(audioSource), engine=Apple Speech Multilingual (EN+ZH)",
            source: "Transcription"
        )

        listeningTask = Task {
            do {
                // Ensure Apple Speech models are ready (EN-US + ZH-Hans)
                if !(await speechModelManager.ensureBilingualModelsReady()) {
                    ErrorLogger.shared.log(
                        "startListening: Apple Speech EN+ZH models not ready",
                        source: "Transcription"
                    )
                    showModelNotReadyAlert = true
                    listeningState = .idle
                    return
                }

                let audioStream: AsyncStream<AudioChunk>
                let stop: @Sendable () -> Void

                switch audioSource {
                case .microphone:
                    guard micPermissionGranted else {
                        errorMessage = "Microphone permission not granted"
                        ErrorLogger.shared.log("Microphone permission not granted", source: "AudioCapture")
                        listeningState = .idle
                        return
                    }
                    let capture = audioCaptureService.startCapture()
                    audioStream = capture.stream
                    stop = capture.stop

                case .systemAudio:
                    let capture = try await AppAudioCaptureService.startSystemCapture()
                    audioStream = capture.stream
                    stop = capture.stop

                case .appAudio(let target):
                    guard let target else {
                        errorMessage = "No app selected"
                        ErrorLogger.shared.log("No app selected for audio capture", source: "AudioCapture")
                        listeningState = .idle
                        return
                    }
                    let capture = try await AppAudioCaptureService.startCapture(for: target)
                    audioStream = capture.stream
                    stop = capture.stop
                }

                self.stopAudioCapture = stop
                self.sessionStartTime = Date()

                // Fork audio stream: engine, UI level, recording, and diarization
                let (engineStream, engineContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(256)
                )
                let (levelStream, levelContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                let (recordingStream, recordingContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(256)
                )
                let (diarizationStream, diarizationContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(256)
                )

                // Audio level update task
                audioLevelTask = Task {
                    for await chunk in levelStream {
                        self.audioLevel = chunk.level
                        self.audioLevelHistory.append(chunk.level)
                        if self.audioLevelHistory.count > 30 {
                            self.audioLevelHistory.removeFirst()
                        }
                    }
                }

                // Start recording
                let (recFileName, recStartTime) = audioRecordingService.startRecording()
                self.currentRecordingFileName = recFileName
                jsonlStore.appendRecordingStart(fileName: recFileName, timestamp: recStartTime)

                nonisolated(unsafe) let recorder = audioRecordingService
                recordingTask = Task.detached {
                    for await chunk in recordingStream {
                        recorder.writeChunk(chunk)
                    }
                }

                // Diarization
                DiarizationModelManager.shared.checkStatus()
                let enableDiarization = AppSettings.shared.liveEnableDiarization
                    && DiarizationModelManager.shared.modelStatus.isReady
                self.isDiarizationEnabled = enableDiarization

                if enableDiarization {
                    do {
                        let diarizationModels = try await DiarizationModelManager.shared.loadModels()
                        let diarizationService = try RealtimeDiarizationService()
                        diarizationService.initialize(models: diarizationModels)
                        self.realtimeDiarizationService = diarizationService
                        self.diarizationSegments = []
                        self.activeSpeakerCount = 0

                        try diarizationService.start { [weak self] segments in
                            Task { @MainActor [weak self] in
                                self?.handleDiarizationSegments(segments)
                            }
                        }

                        diarizationTask = Task {
                            for await chunk in diarizationStream {
                                diarizationService.feedAudio(chunk.samples)
                            }
                        }
                    } catch {
                        ErrorLogger.shared.log(
                            "RealtimeDiarizationService failed: \(error.localizedDescription)",
                            source: "RealtimeDiarization"
                        )
                        self.isDiarizationEnabled = false
                    }
                }

                if !isDiarizationEnabled {
                    diarizationTask = Task.detached {
                        for await _ in diarizationStream {}
                    }
                }

                // Fork task — fan out audio to all four consumers
                let forkTask = Task.detached {
                    for await chunk in audioStream {
                        engineContinuation.yield(chunk)
                        levelContinuation.yield(chunk)
                        recordingContinuation.yield(chunk)
                        diarizationContinuation.yield(chunk)
                    }
                    engineContinuation.finish()
                    levelContinuation.finish()
                    recordingContinuation.finish()
                    diarizationContinuation.finish()
                }

                // Start Apple Speech Multilingual Engine (EN+ZH concurrently)
                ErrorLogger.shared.log(
                    "startListening: initializing MultilingualSpeechEngine (en-US + zh-Hans)",
                    source: "Transcription"
                )
                let multilingualEngine = MultilingualSpeechEngine()
                let events = multilingualEngine.processStream(engineStream)

                listeningState = .active
                errorMessage = nil
                ErrorLogger.shared.log(
                    "startListening: Apple Speech Multilingual engine started, diarization=\(enableDiarization), now active",
                    source: "Transcription"
                )

                for await event in events {
                    switch event {
                    case .partial(let text):
                        if partialStartTimestamp == nil && !text.isEmpty {
                            partialStartTimestamp = Date()
                        }
                        currentPartialText = text
                        // Trigger partial translation for Chinese text
                        if translationService.isEnabled {
                            translationService.translatePartial(text)
                        }

                    case .sentenceComplete(var sentence):
                        if isDiarizationEnabled {
                            sentence.speakerId = assignSpeaker(for: sentence)
                        }
                        // Translate Chinese sentences to English
                        if translationService.isEnabled,
                           sentence.detectedLanguage == "zh",
                           !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // Fire-and-forget translation; attach result when ready
                            let textToTranslate = sentence.text
                            Task { [weak self] in
                                guard let self else { return }
                                if let translated = await self.translationService.translateSentence(textToTranslate),
                                   !Task.isCancelled {
                                    // Find and update the sentence
                                    if let idx = await MainActor.run(body: {
                                        self.sentences.firstIndex(where: { $0.id == sentence.id })
                                    }) {
                                        await MainActor.run {
                                            self.sentences[idx].translation = translated
                                            // Also update JSONL
                                            self.rewriteJSONLWithCurrentSentences()
                                        }
                                    }
                                }
                            }
                        }

                        sentences.append(sentence)
                        jsonlStore.appendEntry(sentence: sentence)
                        currentPartialText = ""
                        partialStartTimestamp = nil

                    case .error(let message):
                        errorMessage = message
                        ErrorLogger.shared.log(message, source: "Transcription")
                    }
                }

                forkTask.cancel()

            } catch {
                errorMessage = error.localizedDescription
                ErrorLogger.shared.log("Listening failed: \(error.localizedDescription)", source: "AudioCapture")
            }

            listeningState = .idle
            audioLevel = 0
        }
    }

    func stopListening() {
        guard listeningState == .active || listeningState == .starting else { return }
        ErrorLogger.shared.log(
            "stopListening: sentences=\(sentences.count), partialText=\(currentPartialText.isEmpty ? "(empty)" : "present")",
            source: "Transcription"
        )
        listeningState = .stopping

        // Flush remaining partial text as a final sentence
        if !currentPartialText.isEmpty {
            let trimmed = currentPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let sentence = TranscriptionSentence(
                    startTimestamp: partialStartTimestamp ?? Date(),
                    timestamp: Date(),
                    text: trimmed
                )
                sentences.append(sentence)
                jsonlStore.appendEntry(sentence: sentence)
            }
            currentPartialText = ""
            partialStartTimestamp = nil
        }

        // Stop recording
        if let info = audioRecordingService.stopRecording(), let recFileName = currentRecordingFileName {
            jsonlStore.appendRecordingStop(fileName: recFileName, durationMs: info.durationMs)
        }
        recordingTask?.cancel()
        recordingTask = nil
        currentRecordingFileName = nil

        // Stop diarization
        realtimeDiarizationService?.stop()
        realtimeDiarizationService = nil
        diarizationTask?.cancel()
        diarizationTask = nil
        diarizationSegments = []
        isDiarizationEnabled = false
        activeSpeakerCount = 0
        sessionStartTime = nil

        stopAudioCapture?()
        stopAudioCapture = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        listeningTask?.cancel()
        listeningTask = nil


        listeningState = .idle
        audioLevel = 0
    }

    func toggleListening() {
        if listeningState == .idle {
            startListening()
        } else {
            stopListening()
        }
    }

    // MARK: - Session

    func createNewSession(name: String? = nil) {
        if listeningState != .idle {
            stopListening()
        }
        sentences.removeAll()
        currentPartialText = ""
        jsonlStore.createSession(name: name)
    }

    // MARK: - History

    func clearHistory() {
        sentences.removeAll()
        currentPartialText = ""
    }

    // MARK: - Export

    func exportSRT() async {
        await SRTExporter.exportToFile(sentences: sentences)
    }


    // MARK: - Diarization

    /// Enable or disable live speaker diarization.
    func setDiarizationEnabled(_ enabled: Bool) {
        guard AppSettings.shared.liveEnableDiarization != enabled else { return }
        AppSettings.shared.liveEnableDiarization = enabled

        let wasListening = listeningState == .active
        if wasListening {
            ErrorLogger.shared.log(
                "Changing diarization to \(enabled) while listening — restarting pipeline",
                source: "RealtimeDiarization"
            )
            stopListening()
            Task {
                startListening()
            }
        } else {
            ErrorLogger.shared.log(
                "Changing diarization to \(enabled) while idle — setting only",
                source: "RealtimeDiarization"
            )
        }
    }

    /// Convenience for UI toggle.
    func toggleDiarization() {
        setDiarizationEnabled(!AppSettings.shared.liveEnableDiarization)
    }

    /// Convenience for UI toggle.
    func toggleTranslation() {
        setTranslationEnabled(!translationService.isEnabled)
    }

    /// Handle incoming diarization segments from the streaming pipeline.
    @MainActor
    private func handleDiarizationSegments(_ segments: [RealtimeDiarizationService.SpeakerSegment]) {
        diarizationSegments.append(contentsOf: segments)
        Task {
            activeSpeakerCount = await realtimeDiarizationService?.speakerCount ?? 0
        }

        backfillSpeakerIds()
    }

    /// Assign a speaker to a sentence by matching its time range against diarization segments.
    private func assignSpeaker(for sentence: TranscriptionSentence) -> String? {
        guard let sessionStart = sessionStartTime else { return nil }
        let sentStart = sentence.startTimestamp.timeIntervalSince(sessionStart)
        let sentEnd = sentence.timestamp.timeIntervalSince(sessionStart)

        var bestSpeaker: String?
        var bestOverlap: Double = 0

        for seg in diarizationSegments {
            let overlapStart = max(sentStart, Double(seg.startTime))
            let overlapEnd = min(sentEnd, Double(seg.endTime))
            let overlap = max(0, overlapEnd - overlapStart)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = seg.speakerId
            }
        }

        return bestSpeaker
    }

    /// Backfill speakerId for sentences that were emitted before diarization results arrived.
    private func backfillSpeakerIds() {
        guard let sessionStart = sessionStartTime else { return }
        var changed = false

        for i in sentences.indices where sentences[i].speakerId == nil {
            let sentStart = sentences[i].startTimestamp.timeIntervalSince(sessionStart)
            let sentEnd = sentences[i].timestamp.timeIntervalSince(sessionStart)

            var bestSpeaker: String?
            var bestOverlap: Double = 0

            for seg in diarizationSegments {
                let overlapStart = max(sentStart, Double(seg.startTime))
                let overlapEnd = min(sentEnd, Double(seg.endTime))
                let overlap = max(0, overlapEnd - overlapStart)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = seg.speakerId
                }
            }

            if let speaker = bestSpeaker {
                sentences[i].speakerId = speaker
                changed = true
            }
        }

        if changed {
            rewriteJSONLWithCurrentSentences()
        }
    }

    /// Rewrite the JSONL file with updated speaker IDs after backfill.
    private func rewriteJSONLWithCurrentSentences() {
        guard let fileURL = jsonlStore.currentFileURL else { return }
        let allLines = jsonlStore.readAllLines(from: fileURL)

        var contentIndex = 0
        var updatedLines: [JSONLLine] = []

        for line in allLines {
            switch line {
            case .content(let entry):
                if contentIndex < sentences.count {
                    let sentence = sentences[contentIndex]
                    let updated = JSONLContentEntry(
                        startTime: entry.startTime,
                        endTime: entry.endTime,
                        originalText: entry.originalText,
                        translatedText: entry.translatedText,
                        speakerId: sentence.speakerId
                    )
                    updatedLines.append(.content(updated))
                } else {
                    updatedLines.append(line)
                }
                contentIndex += 1
            default:
                updatedLines.append(line)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        var output = ""
        for (i, line) in updatedLines.enumerated() {
            if let data = try? encoder.encode(line),
               let str = String(data: data, encoding: .utf8) {
                if i > 0 { output += "\n" }
                output += str
            }
        }
        try? output.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}