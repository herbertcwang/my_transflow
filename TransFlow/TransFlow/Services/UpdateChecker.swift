import Foundation
import AppKit

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, releaseNotes: String)
    case downloading(progress: Double)
    case readyToInstall(version: String, pkgURL: URL)
    case installing
    case failed(message: String)
}

@Observable
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private(set) var status: UpdateStatus = .idle

    private static let owner = "Cyronlee"
    private static let repo = "TransFlow"
    private static let githubAPI = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: PKGDownloadDelegate?
    private var hasCheckedThisSession = false

    private init() {}

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkOnceOnLaunch() {
        guard !hasCheckedThisSession else { return }
        Task { await check() }
    }

    func checkForUpdates() {
        Task { await check() }
    }

    func downloadUpdate() {
        guard case .updateAvailable(let version, _) = status else { return }
        Task { await startDownload(version: version) }
    }

    func installUpdate() {
        guard case .readyToInstall(_, let pkgURL) = status else { return }
        status = .installing
        NSWorkspace.shared.open(pkgURL)
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadDelegate = nil
        if case .downloading = status {
            status = .idle
            Task { await check() }
        }
    }

    // MARK: - Private

    private func check() async {
        status = .checking

        do {
            let release = try await fetchLatestRelease()
            let remoteVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            hasCheckedThisSession = true

            if remoteVersion.compare(currentAppVersion, options: .numeric) == .orderedDescending {
                status = .updateAvailable(version: remoteVersion, releaseNotes: release.body ?? "")
            } else {
                status = .upToDate
            }
        } catch is CancellationError {
            return
        } catch {
            ErrorLogger.shared.log("Update check failed: \(error.localizedDescription)", source: "UpdateChecker")
            status = .failed(message: error.localizedDescription)
        }
    }

    private func startDownload(version: String) async {
        do {
            let release = try await fetchLatestRelease()
            guard let pkgAsset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }) else {
                status = .failed(message: "No PKG asset found in release")
                return
            }

            let url = URL(string: pkgAsset.browserDownloadURL)!
            status = .downloading(progress: 0)

            let delegate = PKGDownloadDelegate { [weak self] progress in
                Task { @MainActor in
                    self?.status = .downloading(progress: progress)
                }
            }
            self.downloadDelegate = delegate

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()

            let tempURL = try await delegate.waitForCompletion()

            let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let destURL = downloadsDir.appendingPathComponent("TransFlow-\(version).pkg")

            let fm = FileManager.default
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tempURL, to: destURL)

            self.downloadTask = nil
            self.downloadDelegate = nil
            status = .readyToInstall(version: version, pkgURL: destURL)
        } catch is CancellationError {
            return
        } catch {
            ErrorLogger.shared.log("Update download failed: \(error.localizedDescription)", source: "UpdateChecker")
            status = .failed(message: error.localizedDescription)
            self.downloadTask = nil
            self.downloadDelegate = nil
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: Self.githubAPI)!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

// MARK: - Download Delegate

private final class PKGDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let continuation: UnsafeContinuation<URL, any Error>?

    private final class Box: @unchecked Sendable {
        var continuation: CheckedContinuation<URL, any Error>?
    }
    private let box = Box()

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
        self.continuation = nil
        super.init()
    }

    func waitForCompletion() async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            box.continuation = cont
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".pkg")
        do {
            try fm.moveItem(at: location, to: tempFile)
            box.continuation?.resume(returning: tempFile)
        } catch {
            box.continuation?.resume(throwing: error)
        }
        box.continuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            box.continuation?.resume(throwing: error)
            box.continuation = nil
        }
    }
}

// MARK: - GitHub API Models

private struct GitHubRelease: Codable {
    let tagName: String
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
}

private struct GitHubAsset: Codable {
    let name: String
    let browserDownloadURL: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}
