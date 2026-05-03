import Foundation
import FluidAudio
import AppKit

/// Tracks the download/install status of Qwen3-ASR + Silero VAD models.
enum Qwen3ModelStatus: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case installed
    case failed(message: String)
    case checking

    var isReady: Bool {
        if case .installed = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var displayKey: String {
        switch self {
        case .notDownloaded: "qwen3_model.status_not_downloaded"
        case .downloading: "qwen3_model.status_downloading"
        case .installed: "qwen3_model.status_installed"
        case .failed: "qwen3_model.status_failed"
        case .checking: "qwen3_model.status_checking"
        }
    }
}

/// Manages the lifecycle of Qwen3-ASR and Silero VAD models for multilingual transcription.
///
/// Follows the same patterns as SpeechModelManager (see docs/speech-model-lifecycle.md):
/// - Observes NSApplication.didBecomeActiveNotification to recover from stale cache
/// - Uses ensureModelReady() before every transcription entry point
/// - Re-reserves/re-checks on .notDownloaded before falling through to download
@Observable
@MainActor
final class Qwen3ModelManager {
    static let shared = Qwen3ModelManager()

    /// Overall model status (both Qwen3 ASR + VAD must be ready).
    var modelStatus: Qwen3ModelStatus = .checking

    /// Whether models are actively downloading.
    var isDownloading: Bool = false

    /// Download progress (0.0 – 1.0).
    var downloadProgress: Double = 0

    /// Whether the Qwen3 multilingual feature is available (models installed).
    var isMultilingualAvailable: Bool {
        modelStatus.isReady
    }

    private var lifecycleObserver: (any NSObjectProtocol)?
    private var downloadTask: Task<Bool, Never>?

    /// Cached Qwen3 model directory URL (where downloaded models live).
    private var qwen3ModelDir: URL?

    private init() {
        setupLifecycleObserver()
        Task {
            await checkStatus()
        }
    }

    // MARK: - App Lifecycle

    private func setupLifecycleObserver() {
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleAppBecameActive()
            }
        }
    }

    private func handleAppBecameActive() async {
        ErrorLogger.shared.log(
            "App became active — rechecking Qwen3 model status",
            source: "Qwen3Model"
        )
        await checkStatus()
    }

    // MARK: - Status

    func checkStatus() async {
        modelStatus = .checking

        do {
            // Check if models exist in the default FluidAudio cache location
            let cacheDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            let qwen3Dir = cacheDir.appendingPathComponent("qwen3-asr-coreml")
            let vadDir = cacheDir.appendingPathComponent("silero-vad-coreml")

            let qwen3Exists = FileManager.default.fileExists(atPath: qwen3Dir.path)
            let vadExists = FileManager.default.fileExists(atPath: vadDir.path)

            if qwen3Exists && vadExists {
                qwen3ModelDir = qwen3Dir
                modelStatus = .installed
                ErrorLogger.shared.log(
                    "Qwen3 models found at \(qwen3Dir.path)",
                    source: "Qwen3Model"
                )
            } else {
                modelStatus = .notDownloaded
                ErrorLogger.shared.log(
                    "Qwen3 models not found (qwen3: \(qwen3Exists), vad: \(vadExists))",
                    source: "Qwen3Model"
                )
            }
        } catch {
            modelStatus = .failed(message: error.localizedDescription)
            ErrorLogger.shared.log(
                "Qwen3 status check failed: \(error.localizedDescription)",
                source: "Qwen3Model"
            )
        }
    }

    // MARK: - Download

    func downloadModels() async -> Bool {
        guard !isDownloading else { return false }

        // If already in-flight, wait for it
        if let task = downloadTask {
            return await task.value
        }

        downloadTask = Task { @MainActor in
            isDownloading = true
            modelStatus = .downloading(progress: 0)
            downloadProgress = 0

            do {
                ErrorLogger.shared.log("Downloading Qwen3-ASR models...", source: "Qwen3Model")

                // Download Qwen3 ASR models
                let qwen3Dir = try await Qwen3AsrModels.download()
                modelStatus = .downloading(progress: 0.5)
                downloadProgress = 0.5

                // Initialize VAD manager (auto-downloads Silero VAD)
                let _ = try await VadManager()
                modelStatus = .downloading(progress: 0.9)
                downloadProgress = 0.9

                qwen3ModelDir = qwen3Dir
                modelStatus = .installed
                downloadProgress = 1.0
                isDownloading = false

                ErrorLogger.shared.log(
                    "Qwen3 models downloaded to \(qwen3Dir.path)",
                    source: "Qwen3Model"
                )
                return true
            } catch {
                modelStatus = .failed(message: error.localizedDescription)
                isDownloading = false
                ErrorLogger.shared.log(
                    "Qwen3 model download failed: \(error.localizedDescription)",
                    source: "Qwen3Model"
                )
                return false
            }
        }

        return await downloadTask!.value
    }

    /// Ensure models are ready before transcription. Returns true if models are installed.
    /// Attempts re-check and re-download recovery following the lifecycle pattern.
    func ensureModelReady() async -> Bool {
        await checkStatus()

        if modelStatus.isReady {
            return true
        }

        // If not downloaded, try downloading
        if case .notDownloaded = modelStatus {
            ErrorLogger.shared.log(
                "Qwen3 models not downloaded — initiating download",
                source: "Qwen3Model"
            )
            return await downloadModels()
        }

        // If download failed, try one more time
        if case .failed = modelStatus {
            ErrorLogger.shared.log(
                "Qwen3 models previously failed — retrying download",
                source: "Qwen3Model"
            )
            return await downloadModels()
        }

        return false
    }

    // MARK: - Model Access

    /// Returns the cached Qwen3 model directory URL, or nil if not installed.
    var modelDirectory: URL? {
        qwen3ModelDir
    }
}